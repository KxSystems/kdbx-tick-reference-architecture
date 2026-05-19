#!/bin/bash

# Start all processes for base Tick Architecture.
# Run from the project root directory.
#
# Usage: ./tick/scripts/startup.sh [-s secondaries]
#   -s  Secondary threads per process (default: 0)
#
# All configuration is hardcoded below
# To customize, edit the constants block directly

#################
# Configuration #
#################
# Runtime directories (created automatically below if missing)
TPLOG_DIR="app/tplogs"
HDB_DIR="app/hdb"
PROCESS_LOG_DIR="app/proclogs"

# Schema and analytics inputs
SCHEMA_DIR="samples/schemas"
ANALYTIC_DIR="samples/analytics"

# Tickerplant log file prefix
TPLOG_NAME="tpLog"

# Logging
LOG_LEVEL="info"

# Process ports
TICK_PORT=5010
RDB_PORT=5011
HDB_PORT=5012
GW_PORT=5013
FH_PORT=5014
RTE_PORT=5016

# Feedhandler timer interval (milliseconds)
FH_TIMER=60000

# Export values read by q processes via getenv
export SCHEMA_DIR TPLOG_NAME LOG_LEVEL

###############
# CLI-parsing #
###############
s_flag=0

print_usage() {
  printf "Usage: ./tick/scripts/startup.sh [-s secondaries]\n"
  printf "  -s  Secondary threads per process (default: 0)\n"
}

while getopts 's:' flag; do
  case "${flag}" in
    s) s_flag="${OPTARG}" ;;
    *) print_usage; exit 1 ;;
  esac
done

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
