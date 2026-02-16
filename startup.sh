#!/bin/bash

# Tickerplant
# q tick.q [schema file] [log directory] -p [port number] < /dev/null > [log file] 2>&1 &
q tick.q schemas tplogs -p 5010 < /dev/null > proclogs/tp 2>&1 &

# RDB
# q tick/r.q [:tp port number] -p [port number] < /dev/null > [log file] 2>&1 &
q tick/r.q :5010 -p 5011 < /dev/null > proclogs/rdb 2>&1 &

# RTE

# HDB
# q [hdb directory] -p [port number] < /dev/null > [log file] 2>&1 &
q tplogs/schemas -p 5012 < /dev/null > proclogs/hdb 2>&1 &

# Gateway