#!/usr/bin/env bash

##### VERSION #####
script_version='v0.31'
script_touchdate='14/09/2022'

#####
## Script Configuration
## --------------------------------------------------------------------------------------------------------------------------------------------------------------
#define the path to cassandra
CASSANDRA_CONFIG_DIR="/etc/cassandra"
#define the path to nodetool
CASSANDRA_NODETOOL_DIR="/usr/bin"
#define the port where JMX can be reached
JMX_REMOTE_PORT=8090
#define where the script should write its logfile
LOGDIR="/var/log/cassandra/MaintenanceLog"
#define the name of the logfile
LOGFILE="$LOGDIR/repairlog.log"
#define max logfile size
MAX_LOG_SIZE=100
#select algorithm to determine Full/Primary repair; currently has 2 possible values: 'weeknumber' or 'weightedrandom'; defaults/falls back to weightedrandom
REP_ALGO='weightedrandom'
#Forced Full Repair %
ForceFullRepairThreshold=94

## --------------------------------------------------------------------------------------------------------------------------------------------------------------
#####
## Script History
## --------------------------------------------------------------------------------------------------------------------------------------------------------------
##  Earlier Versions  | - History not available
##  v0.2c  / 05-2021  | - Fixed a few minor bugs wr to logging & improved the handling in general
##                    | - Added check/abort on non-existing cassandra yaml & nodetool pointing to invalid configuration of the 2 variables.
##                    | - more comments
##  v0.2d / 07-2022   | - fixed sorting logic; it never was an issue but didn't adhere to intended operation of picking the 'lowest' IP as command node.
##                    | - some minor fixes & changes to log output; all consistent now
##  v0.2e / 08-2022   | - added a bit of weighted randomized selection of Full Repair or daily Primary Range Repair only; chance is 20% to select a full repair.
##                    | - added duration indicator on script exit
##                    | - more comments / cleaned up a bit
##  v0.2f / 08-2022   | - added additional repair-mode selection algorithm based on weeknumber
##                    | - algortihm seclectable via config flag
##  v0.2g / 08-2022   | - moved selection of Repair Mode from global to per-node
##                    | - minor optimizations, additional comments
##                    | - small adjustment for log maintainer to show actual size, additional comments
##  v0.2h / 08-2022   | - added Nodetool 'info' repair status fetch before initiating a repair action; added override to full repair if <94% repair is reported.
##  v0.3  / 09-2022   | - Fix for 94% override; also configurable now via "ForceFullRepairThreshold" setting.
##  v0.31 / 09-2022   | - minor update: report after-action repair status in log
## --------------------------------------------------------------------------------------------------------------------------------------------------------------
## Script Explanation
#   Using the current date, we first get the mod 7 so we know which day a node should be triggered. This is done via the last octet of the Node's IP.
#   This ensures that all (repairable) nodes are somewhat spread out over time for repairs.
#
#   The logic here is as follows: 
#     - Assuming we have a fully populated subnet of 254 hosts, it will be almost impossible - and superfluous - to repair them all on a single day.
#       but in order to repair each node at least once per week we simply divide them over the day where we can and we add a bit of randomness to the chosen repair method.
#       For a full subnet (an unlikely situation) at most 254/7 => max 37 hosts would be repaired per day.
#
#   The script runs on each node in basically the same way and time-frame.
#   On each node the script queries the cassandra cluster and retrieves a list of the nodes that are in an up/normal state.
#   The node with the lowest IP is selected as the 'Commander' node, the script will then exit on nodes that determine they are NOT the 'Commander'.
#   The "Commander" node will determine, based on the day of the week, which nodes in the cluster are in need of repair and, for each node will select the Repair Mode (Full or Primary Range).
#   Once the Repair Mode is selected the script will launch nodetool with the proper parameters to first obtains the Repair Status and will proceed to execute the repair accordingly.
#   If the Reported Repair status is below 94% the chosen mode will be overridden to full.
#
#     - In general "Primary Range" repairs will suffice but it is recommended to run a "Full" repairs every few weeks; 
#       As the script has no persistent state logic by design a few simple algorithms are introduced:
#         1) a weighted random algorithm with a ~20% chance to select the Full Repair option; this should be sufficient but as it is random there's a probability that repairs will not occur too frequently.
#         2) a simple algorithm based on the weeknumber; this removes the randomness and yields a stable selection of Repair Method during the whole week.
#      The algorithm is selectable via a configuration flag; in case of typos the fallback will be the weighted algorithm.  
#
#   This should be sufficient to ensure a Full Repair gets triggered occasionally.
#
#####
## --------------------------------------------------------------------------------------------------------------------------------------------------------------
#####

# set an array with the names of the days
DayName_array=(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
DOW=$(date +%A) # get today's full name
RUNSTART=$(date +%c)
RUNSTART_EPOCH=$(date +%s)

# this simplifies logging and just makes things clearer to read
function log_write()
{ # nostamp parameter prohibits emitting the timestamp in front of the logline
  if [[ $2 =~ 'nostamp' ]]; then echo "$1" | tee -a $LOGFILE
    else echo "[`date +%Y-%m-%d:%H:%M:%S`] $1" | tee -a $LOGFILE
  fi   
}

# This can happen on multiple occasions for multiple reasons so let's generalize this here...
function exit_script()
{
 local RUNEND_EPOCH=$(date +%s)
 case $1 in  # use a case here so it's easily extendible...
   0) EXITSTATE='Normally' ;;
   *) EXITSTATE='Abnormally';;
 esac
 log_write "Exiting Script $EXITSTATE..."
 local RUNDURATION="$(( ($RUNEND_EPOCH - $RUNSTART_EPOCH) ))"
 log_write "================================================< $RUNSTART / Duration: $RUNDURATION Seconds / exit code: $1 / Done! >==" nostamp
 exit $1
}

# Possible repair options
REPAIR_OPTION_FLAGS=('full' 'pr')

# we'll use this to determine a weighted random selection of REPAIR_OPTIONS.
weighted_selection() {
local ary=("$@")
case $(( RANDOM % 10 )) in # $RANDOM = 0-32768, mod 10 gives us 0..9 as a result with ~10% chance for each
     2|3 ) index=0 ;;      # 2x out of ten it will select this index, so ~20% chance.
        *) index=1 ;;      # remaining is 8x out of ten
esac
echo ${ary[index]}
}

# we'll use this to determine a stable, weeknumber based selection of REPAIR_OPTIONS.
weeknum_mod(){
  local ary=("$@")
  local WKNUM=(date +%V) # get ISO weeknumber (1..53)  
  case $(($WKNUM %3)) in  # take mod 3 of weeknum, this will yield 0,1 or 2 as a result; every third week we should go for a full repair.
          0|1) index=1;;
          *) index=0;;
  esac
  echo ${ary[index]}
 }



if [ -f $LOGFILE ]; then # only if file exists..
        # wipe large logfile; note there is also a seperate script available that can be set as a systemd 'service' to maintain the logfile
        # included in case the log maintainer is not used so we still have some assurance of basic maintenance!
  LOGFILESIZE=$(du -sm "$LOGFILE" | cut -f 1)
        if [ $LOGFILESIZE -lt $MAX_LOG_SIZE ]; then 
                LOGSTAT="Logfile $LOGFILE (now: $LOGFILESIZE MiB) size below $MAX_LOG_SIZE MiB threshold."
         else
                rm -f $LOGFILE
                LOGSTAT="Logfile $LOGFILE (now: $LOGFILESIZE MiB) exceeded $MAX_LOG_SIZE MiB threshold - logfile was cleared!"
        fi
   else LOGSTAT="Logfile $LOGFILE does not exist - started a fresh one!" 
fi

# if directory does not exist
if [ ! -d $LOGDIR ]; then 
 mkdir -p $LOGDIR > /dev/null  # create the logfolder
fi

clear
log_write "== Cassandra Node Maintenance bash Magic $script_version / RTi (Last updated: $script_touchdate) ==" nostamp
log_write "==< Start / $RUNSTART >===========================================================================================" nostamp
log_write "Starting Cassandra 3 Repair Script ..."
log_write "Reading Cassandra Configuration from: $CASSANDRA_CONFIG_DIR/cassandra.yaml"
log_write "Using nodetool location: $CASSANDRA_NODETOOL_DIR "
log_write "Using algorithm ($REP_ALGO) to select Repair Mode."
log_write "Logging to journal/stdout & Writing logfile to: $LOGFILE"
log_write "$LOGSTAT"

#check if config file / nodetool can be found...
 if [ ! -f $CASSANDRA_CONFIG_DIR/cassandra.yaml ] || [ ! -f $CASSANDRA_NODETOOL_DIR/nodetool ]; then 
   log_write "Error => Unable to find cassandra.yaml ($CASSANDRA_CONFIG_DIR ??) or nodetool ($CASSANDRA_NODETOOL_DIR ??) - most likely a script configuration error! Aborting!"
   exit_script 1
fi


# First figure out local listening Address...

#log_write "Determining this node's listening address from $CASSANDRA_CONFIG_DIR/cassandra.yaml..."
Local_Listen_Address=$(cat $CASSANDRA_CONFIG_DIR/cassandra.yaml | grep "listen_address:" | cut -d " " -f 2)

if [ -z $Local_Listen_Address ]; then  # failsafe, try the hostname if above fails...
       Local_Listen_Address=`hostname -i`
     fi
log_write "Using Listen Address (determined from $CASSANDRA_CONFIG_DIR/cassandra.yaml): $Local_Listen_Address ..."

# now see if we can reach it!

log_write "Querying Node Status..."
NodeStatusArray=($($CASSANDRA_NODETOOL_DIR/nodetool -h $Local_Listen_Address -p $JMX_REMOTE_PORT status 2> /dev/null | grep "UN " | awk '{print $2}' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n ))
# The returned array SHOULD be properly sorted with the lowest number in position #0...

if [ -z "$NodeStatusArray" ]; then ## Array is empty OR failed to execute cassandra/nodetool? We exit hard here so we dont end up doing nonsense!
    log_write "Error => Cassandra Service seems down/unreachable on Node ($Local_Listen_Address) or we received an unexpected response ==> Unable to perform action - Aborting!"
    exit_script 1
    else
      log_write "Node $Local_Listen_Address successfully contacted..."

fi

Array_len=${#NodeStatusArray[@]} #get the length of the array

#log_write "$Array_len Nodes that Reported as Up/Normal..."
#echo "$NodeStatusArray" | nl -n rn | tee -a $LOGFILE

log_write "Detected $Array_len nodes with UN (Up + Normal) status..."

for (( i=0; i<=$(( $Array_len -1 )); i++ ))
do
    day=$(($i%7))
    echo -ne "\t\t      Node ${NodeStatusArray[$i]} repair due on ${DayName_array[$day]} " | tee -a $LOGFILE
    if [[ "${DayName_array[$day]}" == "$DOW" ]]; then 
                                                      log_write "==> Repair due today...Adding it to the list!" nostamp
                                                      Nodes_To_Repair_Today_Array+=( ${NodeStatusArray[$i]} )
     else
        log_write "==> NOT due today!" nostamp
     fi
done

Repair_Array_len=${#Nodes_To_Repair_Today_Array[@]} #get the length of the array


if [ "$Repair_Array_len" -gt 0 ]; then # if there is more than 1 item to repair in the list, pick the first item as the Commander node.
   log_write "$Repair_Array_len Nodes due for Repair Today:"
   echo "$Nodes_To_Repair_Today_Array" | nl -n rn | tee -a $LOGFILE
   log_write "*ASSUMING* : This Node will take the 'Commander' role: ${NodeStatusArray[0]}"
   Commander_Node=${NodeStatusArray[0]}

   else
      log_write "No ($Repair_Array_len) Nodes due for Repair Today!"
      exit_script 0
fi

if [[ "$Local_Listen_Address" = "$Commander_Node" ||  "$Local_Listen_Address" = "localhost" ]] ; then
                                                     log_write "Current node ($Local_Listen_Address) has the Commander role - Proceeding to Repair Action..."
                                                     for Node in $Nodes_To_Repair_Today_Array; do # for each node in need of repair...
                                                            #first get the repair status via nodetool
                                                            NodeRepairStatus=$( $CASSANDRA_NODETOOL_DIR/nodetool -h $Node -p $JMX_REMOTE_PORT info | grep "Percent Repaired" | awk -F: '{sub("%", "", $2); print $2}' )
							    NodeRepairStatus=${NodeRepairStatus%.*} # strip off the fractional bits
                                                            log_write "Node $Node reports: $NodeRepairStatus Percent Repaired"

						           # overwrite chosen method to full in cases where it's < ForceFullRepairThreshold!      
                                                            
							   if [ $NodeRepairStatus -lt $ForceFullRepairThreshold ]; then   
						   	      log_write "Repair status below threshold (<$ForceFullRepairThreshold%), forcing Full Repair Mode!"
						              REPAIR_OPTION="-full"
						           else 
  	   							# if >94%, just use the algorithm to select a method by 'chance'
							        log_write "Repair Status within threshold (>$ForceFullRepairThreshold%), Selecting mode via configured algortihm." 

						   	        # select the repair mode here
					      	                case $REP_ALGO in
								# note both responses ADD the parameter 'dash' on the front...
								   weeknumber) REPAIR_OPTION="-$(weeknum_mod "${REPAIR_OPTION_FLAGS[@]}")"
								   	    ;;
			                                        	    *) # we'll use this as default/fallback
									       REPAIR_OPTION="-$(weighted_selection "${REPAIR_OPTION_FLAGS[@]}")" 
									    ;;
								esac
							    fi

							    case $REPAIR_OPTION in
							         -full)
							                log_write "Repair Method selected: Full Repair ($REPAIR_OPTION)"
   							     	     ;;
							           -pr)
					  		  	        log_write "Repair Method selected: Primary Range Repair ($REPAIR_OPTION)"
				 			    	     ;;
							     esac
                                                           
                                                            #log_write "Starting nodetool..."

                                                            log_write " ==> Executing repair action ($REPAIR_OPTION) against $Node: $CASSANDRA_NODETOOL_DIR/nodetool -h $Node -p $JMX_REMOTE_PORT repair $REPAIR_OPTION" nostamp
                                                            # now we start the command...
                                                            $CASSANDRA_NODETOOL_DIR/nodetool -h $Node -p $JMX_REMOTE_PORT repair $REPAIR_OPTION | tee -a $LOGFILE

                                                                    if [ $? -ne 0 ]; then
                                                                        log_write "Error => Error while running the repair job on Node $Node !!"
                                                                        exit_script 1
                                                                                                        
                                                                    else
                                                                        log_write "Finished nodetool -h $Node -p $JMX_REMOTE_PORT repair $REPAIR_OPTION"
                                                                         NodeNewRepairStatus=$( $CASSANDRA_NODETOOL_DIR/nodetool -h $Node -p $JMX_REMOTE_PORT info | grep "Percent Repaired" | awk -F: '{sub("%", "", $2); print $2}' )
							                 NodeNewRepairStatus=${NodeNewRepairStatus%.*} # strip off the fractional bits
                                                            		 log_write "After Repair Node $Node reports: $NodeNewRepairStatus Percent Repaired"								        
                                                                        exit_script 0
                                                                    fi
                                                        done
  else
   log_write "Current Machine ($Local_Listen_Address) is NOT the Commander ==> Skipping Repair Action and leaving this to the Commander Node ($Commander_Node)."
   exit_script 0
 fi