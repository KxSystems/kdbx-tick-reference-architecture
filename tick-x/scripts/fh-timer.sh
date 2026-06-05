#!/bin/bash

# Start or stop the feedhandler ingest timer without restarting the FH process
# Source this file to expose start_fh_timer and stop_fh_timer functions
#
# Usage:
#   source ./tick-x/scripts/fh-timer.sh
#   start_fh_timer   # enable ingest at $FH_TIMER ms intervals
#   stop_fh_timer    # pause ingest
#
# All configuration is hardcoded below — keep in sync with tick-x/scripts/startup.sh

#################
# Configuration #
#################
FH_PORT=5014
FH_TIMER=60000

FH_URL="::$FH_PORT"

start_fh_timer() {
  echo "fh:hopen \`$FH_URL; fh\"\\\\t $FH_TIMER\";exit 0" | q
  echo "FH timer started on port $FH_PORT at $FH_TIMER ms"
}

stop_fh_timer() {
  echo "fh:hopen \`$FH_URL; fh\"\\\\t 0\";exit 0" | q
  echo "FH timer stopped on port $FH_PORT"
}
