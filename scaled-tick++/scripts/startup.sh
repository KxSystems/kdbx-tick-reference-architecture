#!/bin/bash

# Start all processes for the Scaled Tick++ Reference Architecture.
# Run from the project root directory.
#
# Usage: ./scaled-tick++/scripts/startup.sh [-e envFile] [-s secondaries] [-m chainedRdbs]
#   -e  Path to .env file (default: .env)
#   -s  Secondary threads per process (default: 0)
#   -m  Number of chained RDB replicas for failover (default: 1, minimum: 1)
#       Each replica is paired with a dedicated HDB instance.
#
# The leader RDB is dedicated to intraday writedown (it flushes int-partitions to the IDB
# and merges them into the HDB at EOD) and does NOT serve rdb-tier queries, so at least one
# chained replica (-m >= 1) is required to serve them. Use -m >= 2 for query continuity
# through a leader failure (one replica is promoted to writedown, others keep serving).

e_flag=".env"
s_flag=0
m_flag=1

print_usage() {
  printf "Usage: ./scaled-tick++/scripts/startup.sh [-e envFile] [-s secondaries] [-m chainedRdbs]\n"
  printf "  -e  Path to .env file (default: .env)\n"
  printf "  -s  Secondary threads per process (default: 0)\n"
  printf "  -m  Number of chained RDB replicas for failover (default: 1, minimum: 1)\n"
}

while getopts 'e:s:m:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    m) m_flag="${OPTARG}" ;;
    *) print_usage; exit 1 ;;
  esac
done

if [ "$m_flag" -lt 1 ]; then
  echo "scaled-tick++ requires at least one chained RDB replica (-m >= 1):"
  echo "  the leader RDB is dedicated to writedown and does not serve rdb-tier queries,"
  echo "  so at least one follower is needed to serve them."
  exit 1
fi

if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

# IDB staging dir must exist before the leader's first flush.
mkdir -p "$IDB_DIR"

# Port allocation for chained RDB/HDB pairs.
# Paired scheme: PARALLEL_PORT_RANGE_START + 2*i (RDB_CHAIN_i), +2*i+1 (HDB_EXTRA_i)
RDB_CHAIN_PORTS=()
HDB_EXTRA_PORTS=()
for ((i=0; i<m_flag; i++)); do
  RDB_CHAIN_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 2*i )) )
  HDB_EXTRA_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 2*i + 1 )) )
done

ALL_HDB_PORTS=($HDB_PORT ${HDB_EXTRA_PORTS[*]})

echo -e "Starting Scaled Tick++ Reference Architecture..."
echo -e "  .env:             [$e_flag]"
echo -e "  Secondaries:      [$s_flag]"
echo -e "  Chained RDBs:     [$m_flag]"
echo -e "  Flush interval:   [${FLUSH_INTV_MIN} min]"
echo -e "  Req timeout:      [${REQ_TIMEOUT}]"
echo -e "  RDB chain ports:  [${RDB_CHAIN_PORTS[*]}]"
echo -e "  HDB extra ports:  [${HDB_EXTRA_PORTS[*]}]"
echo -e "  REST_GWs:         [${REST_GW_COUNT}]  (shared port rp,${REST_PORT})"
echo ""

# ── Tickerplant ──────────────────────────────────────────────────────────
q scaled-tick++/src/tick.q \
  -p $TICK_PORT -s $s_flag \
  -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
  -procName TP \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started TP\t\t[$TICK_PORT]"

# ── IDB (single intraday DB) ──────────────────────────────────────────────
# Start before the RDBs so the leader's first flush signal lands on a live IDB.
q scaled-tick++/src/idb.q \
  -p $IDB_PORT -s $s_flag \
  -hdbDir $HDB_DIR -idbDir $IDB_DIR \
  -procName IDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started IDB\t\t[$IDB_PORT]"

# ── RDB (writedown leader) ────────────────────────────────────────────────
q scaled-tick++/src/rdb.q \
  -p $RDB_PORT -s $s_flag \
  -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -idbDir $IDB_DIR \
  -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
  -idbPort $IDB_PORT -flushIntvMin $FLUSH_INTV_MIN \
  -procName RDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RDB\t\t[$RDB_PORT]"

# ── Chained RDB replicas (query servers + failover followers) ─────────────
# Configured for writedown too: any follower may be promoted to leader, at which point
# its MAIN_FLAG-gated flush begins. Until then it serves rdb-tier queries via the gateway.
for ((i=0; i<m_flag; i++)); do
  q scaled-tick++/src/rdb.q \
    -p ${RDB_CHAIN_PORTS[$i]} -s $s_flag \
    -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -idbDir $IDB_DIR \
    -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
    -idbPort $IDB_PORT -flushIntvMin $FLUSH_INTV_MIN \
    -procName RDB_CHAIN_$i \
    < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo -e "  Started RDB_CHAIN_$i\t[${RDB_CHAIN_PORTS[$i]}]"
done

# ── HDB (base) ────────────────────────────────────────────────────────────
q scaled-tick++/src/hdb.q \
  -p $HDB_PORT -s $s_flag \
  -hdbDir $HDB_DIR \
  -procName HDB \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started HDB\t\t[$HDB_PORT]"

# ── Extra HDBs (paired with chained RDB replicas) ────────────────────────
for ((i=0; i<m_flag; i++)); do
  q scaled-tick++/src/hdb.q \
    -p ${HDB_EXTRA_PORTS[$i]} -s $s_flag \
    -hdbDir $HDB_DIR \
    -procName HDB_EXTRA_$i \
    < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo -e "  Started HDB_EXTRA_$i\t[${HDB_EXTRA_PORTS[$i]}]"
done

# ── Feedhandler ───────────────────────────────────────────────────────────
q scaled-tick++/src/fh.q \
  -p $FH_PORT -s $s_flag \
  -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER \
  -tpPort $TICK_PORT \
  -procName FH \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started FH\t\t[$FH_PORT]"

# ── Real-Time Engine ──────────────────────────────────────────────────────
q scaled-tick++/src/rte.q \
  -p $RTE_PORT -s $s_flag \
  -enrichFile $RTE_ENRICH_FILE \
  -tpPort $TICK_PORT \
  -procName RTE \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RTE\t\t[$RTE_PORT]"

# ── Gateway (q-IPC, deferred sync) ────────────────────────────────────────
# Pure q-IPC entry point; no REST in-process. REST_GW(s) below speak q-IPC here.
q scaled-tick++/src/gw.q \
  -p $GW_PORT -s $s_flag \
  -rdbPort $RDB_PORT \
  -crdbPort ${RDB_CHAIN_PORTS[*]} \
  -idbPort $IDB_PORT \
  -hdbPort ${ALL_HDB_PORTS[*]} \
  -reqTimeout $REQ_TIMEOUT \
  -procName GW \
  < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started GW\t\t[$GW_PORT]"

# ── REST_GW (HTTP front-end, sync IPC client of GW) ───────────────────────
# Each instance shares $REST_PORT via SO_REUSEPORT (kdb `rp` mode); on Linux the
# kernel load-balances incoming HTTP connections across them. On macOS BSD,
# SO_REUSEPORT semantics differ — running >1 REST_GW is mostly demonstrative.
for ((i=0; i<REST_GW_COUNT; i++)); do
  q scaled-tick++/src/restgw.q \
    -p rp,$REST_PORT -s $s_flag \
    -gwPort $GW_PORT \
    -analyticsDir $ANALYTIC_DIR \
    -procName REST_GW_$i \
    < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo -e "  Started REST_GW_$i\t[rp,$REST_PORT]"
done

echo -e "\nStack started. Logs: $PROCESS_LOG_DIR/startup.log"
