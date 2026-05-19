#!/bin/bash

# Start all processes for Tick++ Architecture (intraday writedown via main RDB + chained RDB + IDB)
# Run from the project root directory.
#
# Usage: ./tick++/scripts/startup.sh [-s secondaries]
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
IDB_DIR="app/idb"
PROCESS_LOG_DIR="app/proclogs"

# Schema, analytics inputs
SCHEMA_DIR="samples/schemas"
ANALYTIC_DIR="samples/analytics"

# Tickerplant log file prefix
TPLOG_NAME="tpLog"

# Logging
LOG_LEVEL="info"

# Process ports
TICK_PORT=5010
RDB_PORT=5011          # main RDB (writedown role)
HDB_PORT=5012
GW_PORT=5013
FH_PORT=5014
IDB_PORT=5015
RTE_PORT=5016
CHAINED_RDB_PORT=5017    # chained RDB (query role)

# Feedhandler timer interval (milliseconds)
FH_TIMER=60000

# Main RDB intraday flush interval (minutes) — drives both .rdb.flush cadence
# and the IDB reload signal frequency
FLUSH_INTV_MIN=5

# Export values read by q processes via getenv
export SCHEMA_DIR TPLOG_NAME LOG_LEVEL PROCESS_LOG_DIR

###############
# CLI-parsing #
###############
s_flag=0

print_usage() {
  printf "Usage: ./tick++/scripts/startup.sh [-s secondaries]\n"
  printf "  -s  Secondary threads per process (default: 0)\n"
}

while getopts 's:' flag; do
  case "${flag}" in
    s) s_flag="${OPTARG}" ;;
    *) print_usage; exit 1 ;;
  esac
done

# Auto-create runtime directories so the q redirections below don't fail
mkdir -p "$TPLOG_DIR" "$HDB_DIR" "$IDB_DIR" "$PROCESS_LOG_DIR"

echo -e "Starting Tick++ Reference Architecture..."
echo -e "  Secondaries:      [$s_flag]"
echo -e "  Flush interval:   [${FLUSH_INTV_MIN} min]"
echo ""

###############
# Tickerplant #
###############
q tick++/src/tick.q \
  -p $TICK_PORT -s $s_flag \
  -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
  -procName TP \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started TP\t\t[$TICK_PORT]"

#######
# IDB #
#######
# Start IDB before the main RDB so that the first flush signal lands on a live IDB.
q tick++/src/idb.q \
  -p $IDB_PORT -s $s_flag \
  -hdbDir $HDB_DIR -idbDir $IDB_DIR \
  -procName IDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started IDB\t\t[$IDB_PORT]"

##############################
# RDB (writedown role)       #
##############################
q tick++/src/rdb.q \
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
q tick++/src/chainedrdb.q \
  -p $CHAINED_RDB_PORT -s $s_flag \
  -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
  -tpPort $TICK_PORT \
  -procName CHAINED_RDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started CHAINED_RDB\t[$CHAINED_RDB_PORT]"

#######
# HDB #
#######
q tick++/src/hdb.q \
  -p $HDB_PORT -s $s_flag \
  -hdbDir $HDB_DIR \
  -procName HDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started HDB\t\t[$HDB_PORT]"

###############
# Feedhandler #
###############
q tick++/src/fh.q \
  -p $FH_PORT -s $s_flag \
  -fhTimer $FH_TIMER \
  -tpPort $TICK_PORT \
  -procName FH \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started FH\t\t[$FH_PORT]"

####################
# Real-time Engine #
####################
q tick++/src/rte.q \
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
q tick++/src/gw.q \
  -p $GW_PORT -s $s_flag \
  -rdbPort $CHAINED_RDB_PORT \
  -idbPort $IDB_PORT \
  -hdbPort $HDB_PORT \
  -analyticsDir $ANALYTIC_DIR \
  -procName GW \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started GW\t\t[$GW_PORT]"

echo -e "\nStack started. Logs: $PROCESS_LOG_DIR/startup.log"
