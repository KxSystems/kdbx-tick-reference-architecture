#!/bin/bash

# get the process IDs of all q processes with a -procName argument
kill -9 $(ps aux | grep  "q*-procName TP\|RDB\|HDB" | grep -v "grep" | awk '{print $2}')