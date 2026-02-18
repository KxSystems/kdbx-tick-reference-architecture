#!/bin/bash

# Expect to be run from the x-starter directory

# Source env vars
source .env

# Tickerplant
# q tick.q [schema file] [log directory] -p [port number] < /dev/null > [log file] 2>&1 &
q kdb-tick/tick.q -p $TICK_PORT -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR -procName TP < /dev/null > $PROCESS_LOG_DIR/tp 2>&1 &

# RDB
# q tick/r.q [:tp port number] -p [port number] < /dev/null > [log file] 2>&1 &
q kdb-tick/r.q -p $RDB_PORT -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort :$TICK_PORT -hdbPort :$HDB_PORT -procName RDB < /dev/null > $PROCESS_LOG_DIR/rdb 2>&1 &

# RTE
# symbol selection example

# HDB
# q [hdb directory] -p [port number] < /dev/null > [log file] 2>&1 &
#TODO: wait until rdb started before starting hdb (or atleast until directory exists)
q $HDB_DIR -p $HDB_PORT -procName HDB < /dev/null > $PROCESS_LOG_DIR/hdb 2>&1 &

# Gateway
q gw.q -p $GW_PORT -rdbPort $RDB_PORT -hdbPort $HDB_PORT -procName GW
