#!/bin/bash

# Expect to be run from the x-starter directory
CWD=$(pwd)

# Source env vars
source .env

# Move to tick.q directory
cd $TICK_DIR

# Tickerplant
# q tick.q [schema file] [log directory] -p [port number] < /dev/null > [log file] 2>&1 &
q tick.q $SCHEMA_NAME $DATA_LOG_DIR -p $TICK_PORT -procName TP < /dev/null > $PROCESS_LOG_DIR/tp 2>&1 &

# RDB
# q tick/r.q [:tp port number] -p [port number] < /dev/null > [log file] 2>&1 &
q tick/r.q :$TICK_PORT -p $RDB_PORT -procName RDB < /dev/null > $PROCESS_LOG_DIR/rdb 2>&1 &

# RTE
# symbol selection example

# HDB
# q [hdb directory] -p [port number] < /dev/null > [log file] 2>&1 &
#TODO: wait until rdb started before starting hdb
q $DATA_LOG_DIR/$SCHEMA_NAME -p $HDB_PORT -procName HDB < /dev/null > $PROCESS_LOG_DIR/hdb 2>&1 &

# Gateway
cd $CWD
q gw.q -p $GW_PORT -rdbPort $RDB_PORT -hdbPort $HDB_PORT -procName GW
