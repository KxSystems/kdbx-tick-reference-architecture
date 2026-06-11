#!/bin/bash

# Start all processes for Tick-X Architecture (intraday writedown via main RDB + chained RDB + IDB)
# Run from the project root directory.
#
# Usage: ./tick-x/scripts/startup.sh [-s secondaries] [-e envfile]
#   -s  Secondary threads per process (default: 0)
#   -e  Path to the shared env config file (default: samples/sample_env)
#
# All ports, paths, and intervals live in the shared env file (sourced below),
# so the tick and tick-x stacks stay in sync. Copy it and pass -e to customize.
# Runtime paths are absolute (derived from ROOT_DIR) because the processes `cd`
# into the HDB root at connect — relative idb/hdb/tplog paths would otherwise
# nest under app/hdb and desync sym enumeration.

#################
# Configuration #
#################
ENV_FILE="samples/sample_env"

###############
# CLI-parsing #
###############
s_flag=0

print_usage() {
  printf "Usage: ./tick-x/scripts/startup.sh [-s secondaries] [-e envfile]\n"
  printf "  -s  Secondary threads per process (default: 0)\n"
  printf "  -e  Path to the shared env config file (default: samples/sample_env)\n"
}

while getopts 's:e:' flag; do
  case "${flag}" in
    s) s_flag="${OPTARG}" ;;
    e) ENV_FILE="${OPTARG}" ;;
    *) print_usage; exit 1 ;;
  esac
done

# Load shared configuration (defines + exports ports, paths, intervals)
if [ ! -f "$ENV_FILE" ]; then
  echo "Config file not found: $ENV_FILE (run from the project root, or pass -e <file>)" >&2
  exit 1
fi
. "$ENV_FILE"

# Auto-create runtime directories so the q redirections below don't fail
mkdir -p "$TPLOG_DIR" "$HDB_DIR" "$IDB_DIR" "$PROCESS_LOG_DIR"

echo -e "Starting Tick-X Reference Architecture..."
echo -e "  Secondaries:      [$s_flag]"
echo -e "  Flush interval:   [${FLUSH_INTV_MIN} min]"
echo ""

###############
# Tickerplant #
###############
q tick-x/src/tick.q \
  -p $TICK_PORT -s $s_flag \
  -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
  -procName TP \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started TP\t\t[$TICK_PORT]"

#######
# IDB #
#######
# Start IDB before the main RDB so that the first flush signal lands on a live IDB.
q tick-x/src/idb.q \
  -p $IDB_PORT -s $s_flag \
  -hdbDir $HDB_DIR -idbDir $IDB_DIR \
  -procName IDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started IDB\t\t[$IDB_PORT]"

##############################
# RDB (writedown role)       #
##############################
q tick-x/src/rdb.q \
  -p $RDB_PORT -s $s_flag \
  -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -idbDir $IDB_DIR \
  -tpPort $TICK_PORT -hdbPort $HDB_PORT -idbPort $IDB_PORT \
  -flushIntvMin $FLUSH_INTV_MIN \
  -procName RDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RDB\t\t[$RDB_PORT]"

##############################
# CHAINED_RDB (query role)     #
##############################
q tick-x/src/chainedrdb.q \
  -p $CHAINED_RDB_PORT -s $s_flag \
  -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -idbDir $IDB_DIR \
  -tpPort $TICK_PORT \
  -procName CHAINED_RDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started CHAINED_RDB\t[$CHAINED_RDB_PORT]"

#######
# HDB #
#######
q tick-x/src/hdb.q \
  -p $HDB_PORT -s $s_flag \
  -hdbDir $HDB_DIR \
  -procName HDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started HDB\t\t[$HDB_PORT]"

###############
# Feedhandler #
###############
q tick-x/src/fh.q \
  -p $FH_PORT -s $s_flag \
  -fhTimer $FH_TIMER \
  -tpPort $TICK_PORT \
  -procName FH \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started FH\t\t[$FH_PORT]"

####################
# Real-time Engine #
####################
q tick-x/src/rte.q \
  -p $RTE_PORT -s $s_flag \
  -tpPort $TICK_PORT \
  -procName RTE \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RTE\t\t[$RTE_PORT]"

###########
# Gateway #
###########
# GW connects to CHAINED_RDB (not main RDB) for the `rdb` tier; queries to the writedown
# RDB would block on flushes. IDB serves the `idb` tier; HDB serves `hdb`.
q tick-x/src/gw.q \
  -p $GW_PORT -s $s_flag \
  -rdbPort $CHAINED_RDB_PORT \
  -idbPort $IDB_PORT \
  -hdbPort $HDB_PORT \
  -analyticsDir $ANALYTIC_DIR \
  -procName GW \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started GW\t\t[$GW_PORT]"

echo -e "\nStack started. Logs: $PROCESS_LOG_DIR/startup.log"
