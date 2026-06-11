#!/bin/bash

# Start all processes for base Tick Architecture.
# Run from the project root directory.
#
# Usage: ./tick/scripts/startup.sh [-s secondaries] [-e envfile]
#   -s  Secondary threads per process (default: 0)
#   -e  Path to the shared env config file (default: samples/sample_env)
#
# All ports, paths, and intervals live in the shared env file (sourced below),
# so the tick and tick-x stacks stay in sync. Copy it and pass -e to customize.

#################
# Configuration #
#################
ENV_FILE="samples/sample_env"

###############
# CLI-parsing #
###############
s_flag=0

print_usage() {
  printf "Usage: ./tick/scripts/startup.sh [-s secondaries] [-e envfile]\n"
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
mkdir -p "$TPLOG_DIR" "$HDB_DIR" "$PROCESS_LOG_DIR"

echo -e "Starting Tick Reference Architecture..."
echo -e "  Secondaries:      [$s_flag]"
echo ""

###############
# Tickerplant #
###############
q tick/src/tick.q \
  -p $TICK_PORT -s $s_flag \
  -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
  -procName TP \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started TP\t[$TICK_PORT]"

#######
# RDB #
#######
q tick/src/rdb.q \
  -p $RDB_PORT -s $s_flag \
  -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
  -tpPort $TICK_PORT -hdbPort $HDB_PORT \
  -procName RDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RDB\t[$RDB_PORT]"

#######
# HDB #
#######
q tick/src/hdb.q \
  -p $HDB_PORT -s $s_flag \
  -hdbDir $HDB_DIR \
  -procName HDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started HDB\t[$HDB_PORT]"

###############
# Feedhandler #
###############
q tick/src/fh.q \
  -p $FH_PORT -s $s_flag \
  -fhTimer $FH_TIMER \
  -tpPort $TICK_PORT \
  -procName FH \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started FH\t[$FH_PORT]"

####################
# Real-time Engine #
####################
q tick/src/rte.q \
  -p $RTE_PORT -s $s_flag \
  -tpPort $TICK_PORT \
  -procName RTE \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RTE\t[$RTE_PORT]"

###########
# Gateway #
###########
q tick/src/gw.q \
  -p $GW_PORT -s $s_flag \
  -rdbPort $RDB_PORT \
  -hdbPort $HDB_PORT \
  -analyticsDir $ANALYTIC_DIR \
  -procName GW \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started GW\t[$GW_PORT]"

echo -e "\nStack started. Logs: $PROCESS_LOG_DIR/startup.log"
