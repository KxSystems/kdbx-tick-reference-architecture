#!/bin/bash

# Simulates N concurrent users sending sync requests to the GW
# Usage: ./tests/load-test.sh -n 10 -p 5013 -t rdb -q "select from energy"

# Defaults
n_clients=10
gw_port=5013
target="rdb"
query="select from energy"

print_usage() {
  printf "Usage: ./tests/load-test.sh -n [num clients] -p [gw port] -t [rdb|hdb] -q [query string]\n"
}

while getopts 'n:p:t:q:' flag; do
  case "${flag}" in
    n) n_clients="${OPTARG}" ;;
    p) gw_port="${OPTARG}" ;;
    t) target="${OPTARG}" ;;
    q) query="${OPTARG}" ;;
    *) print_usage; exit 1 ;;
  esac
done

echo "=== Load Test ==="
echo "  Clients:  $n_clients"
echo "  GW Port:  $gw_port"
echo "  Target:   $target"
echo "  Query:    $query"
echo ""

# Record overall start time
start_time=$(date +%s%N)

# Launch N clients in parallel
# Small stagger to avoid TCP backlog rejection on simultaneous hopen
# In production, clients maintain persistent connections so this isn't an issue
pids=()
for ((i=0; i<n_clients; i++)); do
  q tests/client.q -gwPort $gw_port -target $target -query "$query" -clientId $i 2>&1 &
  pids+=($!)
  sleep 0.005  # 5ms stagger between connection attempts
done

# Wait for all clients to finish
echo "Waiting for $n_clients clients..."
echo ""

failures=0
for pid in "${pids[@]}"; do
  wait $pid
  if [ $? -ne 0 ]; then
    ((failures++))
  fi
done

# Record overall end time
end_time=$(date +%s%N)
elapsed_ms=$(( (end_time - start_time) / 1000000 ))

echo ""
echo "=== Results ==="
echo "  Total time:  ${elapsed_ms}ms"
echo "  Clients:     $n_clients"
echo "  Failures:    $failures"
echo "  Throughput:  ~$(( n_clients * 1000 / elapsed_ms )) req/s"
