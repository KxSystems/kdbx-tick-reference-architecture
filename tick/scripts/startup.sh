#!/bin/bash

# Start all processes for the Tick Reference Architecture.
# Run from the project root directory.
#
# Usage: ./tick/scripts/startup.sh [-e envFile] [-s secondaries]
#   -e  Path to .env file (default: .env)
#   -s  Secondary threads per process (default: 0)

e_flag=".env"
s_flag=0

print_usage() {
  printf "Usage: ./tick/scripts/startup.sh [-e envFile] [-s secondaries]\n"
  printf "  -e  Path to .env file (default: .env)\n"
  printf "  -s  Secondary threads per process (default: 0)\n"
}

while getopts 'e:s:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    *) print_usage; exit 1 ;;
  esac
done

if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

echo -e "Starting Tick Reference Architecture..."
echo -e "  .env:             [$e_flag]"
echo -e "  Secondaries:      [$s_flag]"
echo ""

# ── Tickerplant ──────────────────────────────────────────────────────────
q tick/tick/tick.q \
  -p $TICK_PORT -s $s_flag \
  -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
  -procName TP \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started TP\t[$TICK_PORT]"

# ── RDB ──────────────────────────────────────────────────────────────────
q tick/tick/rdb.q \
  -p $RDB_PORT -s $s_flag \
  -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
  -tpPort $TICK_PORT -hdbPort $HDB_PORT \
  -procName RDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RDB\t[$RDB_PORT]"

# ── HDB ──────────────────────────────────────────────────────────────────
q tick/tick/hdb.q \
  -p $HDB_PORT -s $s_flag \
  -hdbDir $HDB_DIR \
  -procName HDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started HDB\t[$HDB_PORT]"

# ── Feedhandler ───────────────────────────────────────────────────────────
q tick/tick/fh.q \
  -p $FH_PORT -s $s_flag \
  -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER \
  -tpPort $TICK_PORT \
  -procName FH \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started FH\t[$FH_PORT]"

# ── Real-Time Engine ──────────────────────────────────────────────────────
q tick/tick/rte.q \
  -p $RTE_PORT -s $s_flag \
  -enrichFile $RTE_ENRICH_FILE \
  -tpPort $TICK_PORT \
  -procName RTE \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RTE\t[$RTE_PORT]"

# ── Gateway (q-IPC) ───────────────────────────────────────────────────────
q tick/tick/gw.q \
  -p $GW_PORT -s $s_flag \
  -rdbPort $RDB_PORT \
  -hdbPort $HDB_PORT \
  -analyticsDir $ANALYTIC_DIR \
  -procName GW \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started GW\t[$GW_PORT]"

echo -e "\nStack started. Logs: $PROCESS_LOG_DIR/startup.log"
