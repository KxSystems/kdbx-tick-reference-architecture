#!/bin/bash

# Start or stop the feedhandler ingest timer without restarting the FH process
# Source this file to expose start_fh_timer and stop_fh_timer functions
#
# Usage (run from the project root):
#   source ./tick/scripts/fh-timer.sh
#   start_fh_timer   # enable ingest at $FH_TIMER ms intervals
#   stop_fh_timer    # pause ingest
#
# FH_PORT / FH_TIMER come from the shared env file (sourced below), the same one
# used by startup.sh / restart.sh, so the timer always matches the running stack.
# Override with: ENV_FILE=.env source ./tick/scripts/fh-timer.sh

#################
# Configuration #
#################
ENV_FILE="${ENV_FILE:-samples/sample_env}"
if [ -f "$ENV_FILE" ]; then
  . "$ENV_FILE"
else
  echo "Config file not found: $ENV_FILE (source from the project root, or set ENV_FILE)" >&2
fi

FH_URL="::$FH_PORT"

start_fh_timer() {
  echo "fh:hopen \`$FH_URL; fh\"\\\\t $FH_TIMER\";exit 0" | q
  echo "FH timer started on port $FH_PORT at $FH_TIMER ms"
}

stop_fh_timer() {
  echo "fh:hopen \`$FH_URL; fh\"\\\\t 0\";exit 0" | q
  echo "FH timer stopped on port $FH_PORT"
}
