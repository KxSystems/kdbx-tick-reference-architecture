#!/bin/bash

# Expect to be run from the x-starter directory

# Process CLI flags
e_flag=".env"
s_flag=0
m_flag=0
# Help log
print_usage() {
  printf "Usage: ...\n ./startup.sh -e [path to env file] -s [number of secondaries] -m [number of parallel processes]\n"
}

while getopts 'e:s:m:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    m) m_flag="${OPTARG}" ;;
    *) print_usage
       exit 1 ;;
  esac
done


# Source env vars
if [ ! -f $e_flag ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source $e_flag 

echo -e "Parsed command line arguments as:\n  .env file: [$e_flag] \n  Secondaries: [$s_flag] \n  Parallel processes: [$m_flag]"

# Define value of port to start processes on based on env vars and CLI flags
HDB_PORT_END=$(( $PARALLEL_PORT_RANGE_START + m_flag - 1 ))
HDB_PORTS=($HDB_PORT)
for ((i=$PARALLEL_PORT_RANGE_START; i<=HDB_PORT_END; i++)); do
  HDB_PORTS+=("$i")
done

echo -e "  HDB port(s) set as: [${HDB_PORTS[*]}]"

# Start from end of previous range
RDB_PORT_END=$(( HDB_PORT_END + m_flag ))
CHAINED_RDB_PORTS=()
for ((i=HDB_PORT_END+1; i<=RDB_PORT_END; i++)); do
  CHAINED_RDB_PORTS+=("$i")
done
echo -e "  Main RDB port set as: [$RDB_PORT]"
echo -e "  Chained RDB port(s) set as: [${CHAINED_RDB_PORTS[*]}]"

echo -e "\nStarting processes on ports..."

# Tickerplant
# q tick.q -p [port number] -s [number of secondaries] -schemaDir [schema directory] -tplogDir [log directory] -procName [process name] < /dev/null >> [log file] 2>&1 &
q kdb-tick/tick.q -p $TICK_PORT -s $s_flag -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started TP\t\t[$TICK_PORT]"

# RDB
# q r.q -p [port number] -s [number of secondaries] -tplogDir [log directory] -hdbDir [hdb directory] -tpPort [:tp port number] -hdbPort [hdb port number] -procName [process name] < /dev/null >> [log file] 2>&1 &
q kdb-tick/r.q -p $RDB_PORT -s $s_flag -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort :$TICK_PORT -hdbPort ${HDB_PORTS[*]} -procName RDB_MAIN < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started RDB_MAIN\t[$RDB_PORT]"
for i in "${CHAINED_RDB_PORTS[@]}"; do
  q kdb-tick/r.q -p $i -s $s_flag -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort :$TICK_PORT -hdbPort ${HDB_PORTS[*]} -procName RDB_CHAIN_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo -e "  Started RDB_CHAIN\t[$i]"
done

# RTE
# symbol selection example

# HDB
# q hdb.q -p [port number] -s [number of secondaries] -hdbDir [hdb directory] -procName [process name] < /dev/null >> [log file] 2>&1 &
# TODO: 
# - wait until rdb started before starting hdb (or atleast until directory exists)
# - use hdb.q script to add process logging/future analytics
#q kdb-tick/hdb.q -p $HDB_PORT -hdbDir $HDB_DIR -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
for i in "${HDB_PORTS[@]}"; do
  q kdb-tick/hdb.q -p $i -s $s_flag -hdbDir $HDB_DIR -procName HDB_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo -e "  Started HDB\t\t[$i]"
done

# Feedhandler
# q [feedhandler initfile] -p [port number] -customData [custom data] -s [number of secondaries] -tpPort [tp port number] -procName [process name] < /dev/null > [log file] 2>&1 &
q kdb-tick/fh.q -p $FH_PORT -sampleData $SAMPLE_DATA -fhTimer $FH_TIMER -s $s_flag -tpPort $TICK_PORT -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started FH\t\t[$FH_PORT]"

# Gateway
# q gw.q -p [port number] -analyticsDir [analytics directory] -rdbPort [rdb port] -crdbPort [list of chained rdb ports] -hdbPort [hdb port] -procName [process name] < /dev/null >> [log file] 2>&1 &
q kdb-tick/gw.q -p $GW_PORT -s $s_flag -analyticsDir $ANALYTIC_DIR -rdbPort $RDB_PORT -crdbPort ${CHAINED_RDB_PORTS[*]} -hdbPort ${HDB_PORTS[*]} -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
echo -e "  Started GW\t\t[$GW_PORT]"
