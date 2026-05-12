#!/bin/bash

# Restart specific process(es) without taking down the whole stack.
# Usage: ./restart.sh <procName> [-e <envFile>] [-s <secondaries>] [-m <number of query triplets>] [-r <reqTimeout>]
#   procName: TP | RDB | RDB_<N> | RDB_ALL | HDB | HDB_<N> | HDB_ALL | FH | RTE | QR | GW
#             QP_<N> | QP (all) | REST_GW_<N> | REST_GW (all)
#
# Examples:
#   ./restart.sh GW
#   ./restart.sh GW -r 0D00:00:05
#   ./restart.sh QR
#   ./restart.sh RDB              # realtime leader
#   ./restart.sh RDB_1 -m 2       # single triplet
#   ./restart.sh RDB_ALL -m 2     # all chained triplets
#   ./restart.sh HDB              # HDB
#   ./restart.sh HDB_ALL -m 2     # all triplet HDBs
#   ./restart.sh QP_0 -m 2
#   ./restart.sh QP -m 2          # restart all QPs
#   ./restart.sh REST_GW_0        # single REST_GW
#   ./restart.sh REST_GW          # restart all REST_GWs

proc_name=$1
shift

if [ -z "$proc_name" ]; then
  printf "Usage: ./restart.sh <procName> [-e envFile] [-s secondaries] [-m number of query triplets (RDB+HDB+QP)] [-r reqTimeout]\n"
  exit 1
fi

# Defaults
e_flag=".env"
s_flag=0
m_flag=0
req_timeout=""

while getopts 'e:s:m:r:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    m) m_flag="${OPTARG}" ;;
    r) req_timeout="${OPTARG}" ;;
    *) exit 1 ;;
  esac
done

# Source env vars
if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

# Query timeout (seconds) - override via QUERY_TIMEOUT in .env
QUERY_TIMEOUT=${QUERY_TIMEOUT:-60}

# Build port arrays (mirror startup.sh interleaved triplet logic)
RDB_PORTS=()
HDB_PORTS=()
QP_PORTS=()
for ((i=0; i<m_flag; i++)); do
  RDB_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 3*i )) )
  HDB_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 3*i + 1 )) )
  QP_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 3*i + 2 )) )
done

# Kill helper - kills all q processes matching -procName pattern
kill_proc() {
  local pattern=$1
  local pids=$(ps aux | grep "q.*-procName ${pattern}\b" | grep -v grep | awk '{print $2}')
  if [ -n "$pids" ]; then
    echo "  Killing $pattern: $pids"
    echo "$pids" | xargs kill -9 2>/dev/null
    sleep 0.5
  else
    echo "  No running process found for $pattern"
  fi
}

# Launch helpers
launch_TP() {
  q kdb-x-platform/tick.q -p $TICK_PORT -s $s_flag -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started TP [$TICK_PORT]"
}

launch_RDB_base() {
  local all_hdb_ports=($HDB_PORT ${HDB_PORTS[*]})
  q kdb-x-platform/r.q -p $RDB_PORT -T $QUERY_TIMEOUT -s $s_flag -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort $TICK_PORT -hdbPort ${all_hdb_ports[*]} -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started RDB [$RDB_PORT] (T=$QUERY_TIMEOUT)"
}

launch_RDB_triplet() {
  local idx=$1
  q kdb-x-platform/r.q -p ${RDB_PORTS[$idx]} -T $QUERY_TIMEOUT -s $s_flag -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort $TICK_PORT -hdbPort ${HDB_PORTS[$idx]} -procName RDB_$idx < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started RDB_$idx [${RDB_PORTS[$idx]}] (T=$QUERY_TIMEOUT)"
}

launch_HDB_base() {
  q kdb-x-platform/hdb.q -p $HDB_PORT -T $QUERY_TIMEOUT -s $s_flag -hdbDir $HDB_DIR -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started HDB [$HDB_PORT] (T=$QUERY_TIMEOUT)"
}

launch_HDB_triplet() {
  local idx=$1
  q kdb-x-platform/hdb.q -p ${HDB_PORTS[$idx]} -T $QUERY_TIMEOUT -s $s_flag -hdbDir $HDB_DIR -procName HDB_$idx < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started HDB_$idx [${HDB_PORTS[$idx]}] (T=$QUERY_TIMEOUT)"
}

launch_FH() {
  q kdb-x-platform/fh.q -p $FH_PORT -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER -s $s_flag -tpPort $TICK_PORT -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started FH [$FH_PORT]"
}

launch_QR() {
  q kdb-x-platform/qr.q -p $QR_PORT -s $s_flag -procName QR < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started QR [$QR_PORT]"
}

launch_GW() {
  local timeout_arg=""
  [ -n "$req_timeout" ] && timeout_arg="-reqTimeout $req_timeout"
  q kdb-x-platform/gw.q -p $GW_PORT -s $s_flag -qrPort $QR_PORT $timeout_arg -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started GW [$GW_PORT]${timeout_arg:+ (reqTimeout=$req_timeout)}"
}

launch_QP() {
  local idx=$1
  q kdb-x-platform/qp.q -p ${QP_PORTS[$idx]} -T $QUERY_TIMEOUT -s $s_flag \
    -qrPort $QR_PORT -gwPort $GW_PORT \
    -rdbPort ${RDB_PORTS[$idx]} -hdbPort ${HDB_PORTS[$idx]} \
    -procName QP_$idx \
    < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started QP_$idx [${QP_PORTS[$idx]}] → RDB_$idx:${RDB_PORTS[$idx]} HDB_$idx:${HDB_PORTS[$idx]} (T=$QUERY_TIMEOUT)"
}

launch_REST_GW() {
  local idx=$1
  q kdb-x-platform/rest-gw.q -p rp,$REST_PORT -s $s_flag \
    -gwPort $GW_PORT -analyticsDir $ANALYTIC_DIR \
    -procName REST_GW_$idx \
    < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "  Started REST_GW_$idx [rp,$REST_PORT] → GW:$GW_PORT"
}

echo "Restarting [$proc_name]..."

case "$proc_name" in
  TP)
    kill_proc "TP"
    launch_TP
    ;;
  RDB)
    kill_proc "RDB"
    launch_RDB_base
    ;;
  RDB_ALL)
    for ((i=0; i<m_flag; i++)); do
      kill_proc "RDB_$i"
      launch_RDB_triplet $i
    done
    ;;
  RDB_[0-9]*)
    idx=${proc_name#RDB_}
    kill_proc "$proc_name"
    launch_RDB_triplet $idx
    ;;
  HDB)
    kill_proc "HDB"
    launch_HDB_base
    ;;
  HDB_ALL)
    for ((i=0; i<m_flag; i++)); do
      kill_proc "HDB_$i"
      launch_HDB_triplet $i
    done
    ;;
  HDB_[0-9]*)
    idx=${proc_name#HDB_}
    kill_proc "$proc_name"
    launch_HDB_triplet $idx
    ;;
  FH)
    kill_proc "FH"
    launch_FH
    ;;
  QR)
    kill_proc "QR"
    launch_QR
    ;;
  GW)
    kill_proc "GW"
    launch_GW
    ;;
  QP)
    for ((i=0; i<m_flag; i++)); do
      kill_proc "QP_$i"
      launch_QP $i
    done
    ;;
  QP_[0-9]*)
    idx=${proc_name#QP_}
    kill_proc "$proc_name"
    launch_QP $idx
    ;;
  REST_GW)
    # Restart all currently-running REST_GWs. Detect count from running processes.
    rest_max=-1
    for proc in $(ps aux | grep -oP "(?<=-procName )REST_GW_\d+"); do
      i=${proc#REST_GW_}
      if [ "$i" -gt "$rest_max" ] 2>/dev/null; then rest_max=$i; fi
    done
    rest_count=$(( rest_max + 1 ))
    if [ $rest_count -eq 0 ]; then rest_count=${REST_GW_COUNT:-1}; fi
    for ((i=0; i<rest_count; i++)); do
      kill_proc "REST_GW_$i"
      launch_REST_GW $i
    done
    ;;
  REST_GW_[0-9]*)
    idx=${proc_name#REST_GW_}
    kill_proc "$proc_name"
    launch_REST_GW $idx
    ;;
  *)
    echo "Unknown procName: $proc_name"
    echo "Valid: TP | RDB | RDB_ALL | RDB_<N> | HDB | HDB_ALL | HDB_<N> | FH | QR | GW | QP | QP_<N> | REST_GW | REST_GW_<N>"
    exit 1
    ;;
esac

echo "Done."
