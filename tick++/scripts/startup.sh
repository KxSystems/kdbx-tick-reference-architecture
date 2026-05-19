#!/bin/bash

# Start all processes for the Tick Reference Architecture.
# Run from the project root directory.
#
# Usage: ./tick++/scripts/startup.sh [-e envFile] [-s secondaries] [-m chainedRdbs]
#   -e  Path to .env file (default: .env)
#   -s  Secondary threads per process (default: 0)
#   -m  Number of chained RDB replicas for failover (default: 0)
#       Each replica is paired with a dedicated HDB instance.

e_flag=".env"
s_flag=0
m_flag=0

print_usage() {
  printf "Usage: ./tick++/scripts/startup.sh [-e envFile] [-s secondaries] [-m chainedRdbs]\n"
  printf "  -e  Path to .env file (default: .env)\n"
  printf "  -s  Secondary threads per process (default: 0)\n"
  printf "  -m  Number of chained RDB replicas for failover (default: 0)\n"
}

while getopts 'e:s:m:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    m) m_flag="${OPTARG}" ;;
    *) print_usage; exit 1 ;;
  esac
done

if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

# Port allocation for chained RDB/HDB pairs.
# Paired scheme: PARALLEL_PORT_RANGE_START + 2*i (RDB_CHAIN_i), +2*i+1 (HDB_EXTRA_i)
RDB_CHAIN_PORTS=()
HDB_EXTRA_PORTS=()
for ((i=0; i<m_flag; i++)); do
  RDB_CHAIN_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 2*i )) )
  HDB_EXTRA_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 2*i + 1 )) )
done

ALL_HDB_PORTS=($HDB_PORT ${HDB_EXTRA_PORTS[*]})

echo -e "Starting Tick Reference Architecture..."
echo -e "  .env:             [$e_flag]"
echo -e "  Secondaries:      [$s_flag]"
echo -e "  Chained RDBs:     [$m_flag]"
[ $m_flag -gt 0 ] && echo -e "  RDB chain ports:  [${RDB_CHAIN_PORTS[*]}]"
[ $m_flag -gt 0 ] && echo -e "  HDB extra ports:  [${HDB_EXTRA_PORTS[*]}]"
echo ""

# ── Tickerplant ──────────────────────────────────────────────────────────
q tick++/src/tick.q \
  -p $TICK_PORT -s $s_flag \
  -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
  -procName TP \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started TP\t\t[$TICK_PORT]"

# ── RDB (realtime leader) ────────────────────────────────────────────────
q tick++/src/rdb.q \
  -p $RDB_PORT -s $s_flag \
  -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
  -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
  -procName RDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RDB\t\t[$RDB_PORT]"

# ── Chained RDB replicas (failover followers) ────────────────────────────
for ((i=0; i<m_flag; i++)); do
  q tick++/src/rdb.q \
    -p ${RDB_CHAIN_PORTS[$i]} -s $s_flag \
    -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
    -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
    -procName RDB_CHAIN_$i \
    < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo -e "  Started RDB_CHAIN_$i\t[${RDB_CHAIN_PORTS[$i]}]"
done

# ── HDB (base) ────────────────────────────────────────────────────────────
q tick++/src/hdb.q \
  -p $HDB_PORT -s $s_flag \
  -hdbDir $HDB_DIR \
  -procName HDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started HDB\t\t[$HDB_PORT]"

# ── Extra HDBs (paired with chained RDB replicas) ────────────────────────
for ((i=0; i<m_flag; i++)); do
  q tick++/src/hdb.q \
    -p ${HDB_EXTRA_PORTS[$i]} -s $s_flag \
    -hdbDir $HDB_DIR \
    -procName HDB_EXTRA_$i \
    < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo -e "  Started HDB_EXTRA_$i\t[${HDB_EXTRA_PORTS[$i]}]"
done

# ── Feedhandler ───────────────────────────────────────────────────────────
q tick++/src/fh.q \
  -p $FH_PORT -s $s_flag \
  -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER \
  -tpPort $TICK_PORT \
  -procName FH \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started FH\t\t[$FH_PORT]"

# ── Real-Time Engine ──────────────────────────────────────────────────────
q tick++/src/rte.q \
  -p $RTE_PORT -s $s_flag \
  -enrichFile $RTE_ENRICH_FILE \
  -tpPort $TICK_PORT \
  -procName RTE \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RTE\t\t[$RTE_PORT]"

# ── Gateway (q-IPC) ───────────────────────────────────────────────────────
q tick++/src/gw.q \
  -p $GW_PORT -s $s_flag \
  -rdbPort $RDB_PORT \
  -crdbPort ${RDB_CHAIN_PORTS[*]} \
  -hdbPort ${ALL_HDB_PORTS[*]} \
  -analyticsDir $ANALYTIC_DIR \
  -procName GW \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started GW\t\t[$GW_PORT]"

echo -e "\nStack started. Logs: $PROCESS_LOG_DIR/startup.log"
