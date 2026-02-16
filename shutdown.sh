#!/bin/bash

# Expect to be run from the x-starter directory

# Get the process IDs of all q processes with a -procName argument for TP, RDB, or HDB and kill them
kill -9 $(ps aux | grep  "q*-procName TP\|RDB\|HDB" | grep -v "grep" | awk '{print $2}')