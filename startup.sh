#!/bin/bash

# Expect to be run from the x-starter directory

# Process CLI flags
e_flag=".env"
# Help log
print_usage() {
  printf "Usage: ...\n ./startup.sh -e [path to env file]\n"
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

echo -e "Starting processes on ports..."

# Feedhandler
# q [feedhandler initfile] -p [port number] < /dev/null > [log file] 2>&1 &
q kdb-tick/fh.q -p $FH_PORT -procName FH < /dev/null > $PROCESS_LOG_DIR/fh 2>&1 &
echo -e "  Started FH\t[$FH_PORT]"

# Tickerplant
# q tick.q [schema file] [log directory] -p [port number] < /dev/null > [log file] 2>&1 &
q kdb-tick/tick.q -p $TICK_PORT -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started TP\t[$TICK_PORT]"

# RDB
# q tick/r.q [:tp port number] -p [port number] < /dev/null > [log file] 2>&1 &
q kdb-tick/r.q -p $RDB_PORT -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort :$TICK_PORT -hdbPort :$HDB_PORT -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RDB\t[$RDB_PORT]"

# RTE
# symbol selection example

# HDB
# q [hdb directory] -p [port number] < /dev/null > [log file] 2>&1 &
# TODO: 
# - wait until rdb started before starting hdb (or atleast until directory exists)
# - use hdb.q script to add process logging/future analytics
q kdb-tick/hdb.q -p $HDB_PORT -hdbDir $HDB_DIR -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started HDB\t[$HDB_PORT]"

# Gateway
q kdb-tick/gw.q -p $GW_PORT -rdbPort $RDB_PORT -hdbPort $HDB_PORT -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started GW\t[$GW_PORT]"
