#!/bin/bash

# Expect to be run from the x-starter directory

# Process CLI flags
e_flag=".env"

# Help log
print_usage() {
  printf "Usage: ...\n ./fh_timer.sh -e [path to env file]\n"
}

while getopts 'e:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    *) print_usage
       exit 1 ;;
  esac
done


# Source env vars
if [ ! -f $e_flag ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source $e_flag 

#Timer Overwrite Function
#Start FH timer
start_fh_timer(){
  echo "fh:hopen $FH_PORT; fh\"\\\\t $FH_TIMER\";exit 0"|q
  echo "FH timer started on port $FH_PORT at $FH_TIMER ms"
}
#Stop FH timer
stop_fh_timer(){
  echo "fh:hopen $FH_PORT; fh\"\\\\t 0\";exit 0"|q
  echo "FH timer stopped on port $FH_PORT "
}
