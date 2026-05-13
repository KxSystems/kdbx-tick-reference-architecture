#!/bin/bash

# Start or stop the feedhandler ingest timer without restarting the FH process.
# Source this file to expose start_fh_timer and stop_fh_timer functions.
#
# Usage:
#   source ./tick/scripts/fh-timer.sh [-e envFile]
#   start_fh_timer   # enable ingest at $FH_TIMER ms intervals
#   stop_fh_timer    # pause ingest

e_flag=".env"

while getopts 'e:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    *) printf "Usage: source ./tick/scripts/fh-timer.sh [-e envFile]\n"; return 1 ;;
  esac
done

if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  return 1
fi
source "$e_flag"

FH_URL="::$FH_PORT"

start_fh_timer() {
  echo "fh:hopen \`$FH_URL; fh\"\\\\t $FH_TIMER\";exit 0" | q
  echo "FH timer started on port $FH_PORT at $FH_TIMER ms"
}

stop_fh_timer() {
  echo "fh:hopen \`$FH_URL; fh\"\\\\t 0\";exit 0" | q
  echo "FH timer stopped on port $FH_PORT"
}
