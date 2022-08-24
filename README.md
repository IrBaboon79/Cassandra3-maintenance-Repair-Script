# Cassandra3-maintenance-Repair-Script

Overview
--------
A maintenance script for Cassandra 3 (4 untested) nodes written in bash.
Script is stateless; deploy and run on all servers in a similar way (via systemd timer/unit).

Script History
--------------
Earlier Versions    | - History not available
v0.2c  / 05-2021    | - Fixed a few minor bugs wr to logging & improved the handling in general
                    | - Added check/abort on non-existing cassandra yaml & nodetool pointing to invalid configuration of the 2 variables.
                    | - more comments                    
  v0.2d / 07-2022   | - fixed sorting logic; it never was an issue but didn't adhere to intended operation of picking the 'lowest' IP as command node.
                    | - some minor fixes & changes to log output; all consistent now
  v0.2e / 08-2022   | - added a bit of weighted randomized selection of Full Repair or daily Primary Range Repair only; chance is 20% to select a full repair.
                    | - added duration indicator on script exit
                    | - more comments / cleaned up a bit
  v0.2f / 08-2022   | - added additional repair-mode selection algorithm based on weeknumber
                    | - algortihm seclectable via config flag
  v0.2g / 08-2022   | - moved selection of Repair Mode from global to per-node
                    | - minor optimizations, additional comments
                    | - small adjustment for log maintainer to show actual size, additional comments
  v0.2h / 08-2022   | - added Nodetool 'info' repair status fetch before initiating a repair action; added override to full repair if <94% repair is reported.

Script Explanation
------------------
Using the current date, we first get the mod 7 so we know which day a node should be triggered. This is done via the last octet of the Node's IP.
This ensures that all (repairable) nodes are somewhat spread out over time for repairs.

The logic here is as follows: 
  - Assuming we have a fully populated subnet of 254 hosts, it will be almost impossible - and superfluous - to repair them all on a single day.
    but in order to repair each node at least once per week we simply divide them over the day where we can and we add a bit of randomness to the chosen repair method.
    For a full subnet (an unlikely situation) at most 254/7 => max 37 hosts would be repaired per day.

The script runs on each node in basically the same way and time-frame.
On each node the script queries the cassandra cluster and retrieves a list of the nodes that are in an up/normal state.
The node with the lowest IP is selected as the 'Commander' node, the script will then exit on nodes that determine they are NOT the 'Commander'.
The "Commander" node will determine, based on the day of the week, which nodes in the cluster are in need of repair and, for each node will select the Repair Mode (Full or Primary Range).
Once the Repair Mode is selected the script will launch nodetool with the proper parameters to first obtains the Repair Status and will proceed to execute the repair accordingly.
 If the Reported Repair status is below 94% the chosen mode will be overridden to full.

 - In general "Primary Range" repairs will suffice but it is recommended to run a "Full" repairs every few weeks; 
   As the script has no persistent state logic by design a few simple algorithms are introduced:
    1) a weighted random algorithm with a ~20% chance to select the Full Repair option; this should be sufficient but as it is random there's a probability that repairs will not occur too frequently.
    2) a simple algorithm based on the weeknumber; this removes the randomness and yields a stable selection of Repair Method during the whole week.
       The algorithm is selectable via a configuration flag; in case of typos the fallback will be the weighted algorithm.  

This should be sufficient to ensure a Full Repair gets triggered occasionally.
