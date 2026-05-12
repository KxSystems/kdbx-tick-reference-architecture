#!/bin/bash

# Expect to be run from the x-starter directory

# Process CLI flags
e_flag=".env"
s_flag=0
m_flag=0
p_flag="realtime,query"

print_usage() {
  printf "Usage:\n  ./scripts/startup.sh [-e env_file] [-s secondaries] [-m triplets] [-p modules]\n"
  printf "\nModules (-p): comma-separated list of modules to start\n"
  printf "  realtime  — TP, RDB, HDB, FH\n"
  printf "  query     — QR, GW, triplet RDB_N + HDB_N + QP_N\n"
  printf "  Default: realtime,query\n"
  printf "\nExamples:\n"
  printf "  ./scripts/startup.sh -m 2                        # Both modules, 2 triplets\n"
  printf "  ./scripts/startup.sh -p realtime                 # Realtime ingest only\n"
  printf "  ./scripts/startup.sh -p query -m 3               # Query path only, 3 triplets\n"
  printf "  ./scripts/startup.sh -p realtime,query -m 2      # Explicit both\n"
}

while getopts 'e:s:m:p:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    m) m_flag="${OPTARG}" ;;
    p) p_flag="${OPTARG}" ;;
    *) print_usage
       exit 1 ;;
  esac
done

# Module check helper
has_module() { [[ ",$p_flag," == *",$1,"* ]]; }

# Source env vars
if [ ! -f $e_flag ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source $e_flag

# Default query timeout (seconds) for RDB/HDB/QP sync handlers
# Prevents long-running queries from bottlenecking processes. Override via QUERY_TIMEOUT in .env
QUERY_TIMEOUT=${QUERY_TIMEOUT:-60}

# Default request timeout (seconds) for client requests on the GW
# REQ_TIMEOUT should be greater than QUERY_TIMEOUT. Override via REQ_TIMEOUT in .env
#   Suggested setting 1.5x QUERY_TIMEOUT
REQ_TIMEOUT=${REQ_TIMEOUT:-60}

# Number of REST_GW processes to start (scales HTTP concurrency independently
# of query triplets). All share $REST_PORT via SO_REUSEPORT (kdb `rp` mode).
REST_GW_COUNT=${REST_GW_COUNT:-1}

# Build port arrays from PARALLEL_PORT_RANGE_START
# Interleaved by triplet for dynamic scaling support:
#   Triplet i: RDB_i = RANGE + 3*i, HDB_i = RANGE + 3*i + 1, QP_i = RANGE + 3*i + 2
RDB_PORTS=()
HDB_PORTS=()
QP_PORTS=()
for ((i=0; i<m_flag; i++)); do
  RDB_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 3*i )) )
  HDB_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 3*i + 1 )) )
  QP_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 3*i + 2 )) )
done

echo -e "Parsed command line arguments as:"
echo -e "  .env file:    [$e_flag]"
echo -e "  Secondaries:  [$s_flag]"
echo -e "  Modules (-p): [$p_flag]"
echo -e "  Triplets (-m): [$m_flag]"
echo -e "  REST_GWs:     [$REST_GW_COUNT]"

# ── Realtime module ───────────────────────────────────────────────────────
# Processes: TP, RDB, HDB, FH
# Owns the realtime ingest pipeline: feedhandler → tickerplant → RDB → HDB (EOD)

start_realtime() {
    echo -e "\nRealtime path:"

    # Tickerplant
    q kdb-x-platform/tick.q -p $TICK_PORT -s $s_flag -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo -e "  Started TP\t\t[$TICK_PORT]"

    # RDB - realtime leader, handles EOD saves, NOT in the query path
    # If query module is also active, pass triplet HDB ports for EOD reload
    if has_module "query"; then
        ALL_HDB_PORTS=($HDB_PORT ${HDB_PORTS[*]})
    else
        ALL_HDB_PORTS=($HDB_PORT)
    fi
    q kdb-x-platform/r.q -p $RDB_PORT -T $QUERY_TIMEOUT -s $s_flag -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo -e "  Started RDB\t\t[$RDB_PORT]"

    # HDB - always part of realtime (EOD save target)
    q kdb-x-platform/hdb.q -p $HDB_PORT -T $QUERY_TIMEOUT -s $s_flag -hdbDir $HDB_DIR -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo -e "  Started HDB\t\t[$HDB_PORT]"

    # Feedhandler
    q kdb-x-platform/fh.q -p $FH_PORT -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER -s $s_flag -tpPort $TICK_PORT -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo -e "  Started FH\t\t[$FH_PORT]"

    # RTE - Real-Time Engine, subscribes to tables on TP, runs enrichment logic defined in enrichFile
    q kdb-x-platform/rte.q -p $RTE_PORT -s $s_flag -enrichFile $RTE_ENRICH_FILE -schemaDir $SCHEMA_DIR -tpPort $TICK_PORT -procName RTE < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo -e "  Started RTE\t\t[$RTE_PORT]"
}

# ── Query module ──────────────────────────────────────────────────────────
# Processes: QR, GW, triplet RDB_N + HDB_N + QP_N
# Owns the async query pipeline: client → GW → QR → QP → RDB/HDB

start_query() {
    echo -e "\nQuery path:"
    echo -e "  Query timeout (s):  \t[$QUERY_TIMEOUT]"
    echo -e "  Req timeout (s):    \t[$REQ_TIMEOUT]"

    # Chained RDBs - read replicas, one per QP
    # Subscribe to TP for realtime data (if realtime module is running)
    for ((i=0; i<m_flag; i++)); do
      q kdb-x-platform/r.q -p ${RDB_PORTS[$i]} -T $QUERY_TIMEOUT -s $s_flag -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort $TICK_PORT -hdbPort ${HDB_PORTS[$i]} -procName RDB_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
      echo -e "  Started RDB_$i\t\t[${RDB_PORTS[$i]}]"
    done

    # Triplet HDBs - one per QP
    for ((i=0; i<m_flag; i++)); do
      q kdb-x-platform/hdb.q -p ${HDB_PORTS[$i]} -T $QUERY_TIMEOUT -s $s_flag -hdbDir $HDB_DIR -procName HDB_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
      echo -e "  Started HDB_$i\t\t[${HDB_PORTS[$i]}]"
    done

    # Query Router (start before GW and QPs)
    q kdb-x-platform/qr.q -p $QR_PORT -s $s_flag -procName QR < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo -e "  Started QR\t\t[$QR_PORT]"

    # Gateway (start after QR, before QPs) — pure q-IPC gateway
    q kdb-x-platform/gw.q -p $GW_PORT -s $s_flag -reqTimeout $REQ_TIMEOUT -qrPort $QR_PORT -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo -e "  Started GW\t\t[$GW_PORT]"

    # Query Processors (start after QR and GW - connects to both on startup)
    # Each QP_i maps 1:1 to RDB_i and HDB_i
    for ((i=0; i<m_flag; i++)); do
      q kdb-x-platform/qp.q -p ${QP_PORTS[$i]} -T $QUERY_TIMEOUT -s $s_flag \
        -qrPort $QR_PORT \
        -gwPort $GW_PORT \
        -rdbPort ${RDB_PORTS[$i]} \
        -hdbPort ${HDB_PORTS[$i]} \
        -procName QP_$i \
        < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
      echo -e "  Started QP_$i\t\t[${QP_PORTS[$i]}] → RDB_$i:${RDB_PORTS[$i]} HDB_$i:${HDB_PORTS[$i]}"
    done

    # REST Gateways — all share $REST_PORT via SO_REUSEPORT (rp,PORT)
    # Each is a thin HTTP adapter that delegates to GW via q-IPC.
    for ((i=0; i<REST_GW_COUNT; i++)); do
      q kdb-x-platform/rest-gw.q -p rp,$REST_PORT -s $s_flag \
        -gwPort $GW_PORT \
        -analyticsDir $ANALYTIC_DIR \
        -procName REST_GW_$i \
        < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
      echo -e "  Started REST_GW_$i\t[rp,$REST_PORT] → GW:$GW_PORT"
    done
}

# ── Start requested modules ──────────────────────────────────────────────

echo -e "\nStarting processes..."
has_module "realtime" && start_realtime
has_module "query" && start_query
