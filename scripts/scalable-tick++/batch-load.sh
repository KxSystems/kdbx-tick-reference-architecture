#!/bin/bash

# Batch load a file (CSV, TXT, parquet) into the HDB as a date-partitioned splayed table.
# Handles compressed files (.gz, .zip, .zst) by decompressing to a temp file first.
# Triggers HDB reload on all running HDB processes after successful load.
#
# Usage:
#   ./scripts/batch-load.sh -f <file> -t <table> -d <date> [-D <delimiter>] [-s <sym>] [-C <colMap>] [-e <envFile>] [-m <mode>]
#
# Required:
#   -f  Path to data file (CSV, TXT, parquet). Supports .gz/.zip/.zst compressed files.
#   -t  Target table name (must match a schema in SCHEMA_DIR)
#   -d  Partition date (YYYY.MM.DD format)
#
# Optional:
#   -D  Delimiter character for text files (default: comma)
#   -s  Default sym value to inject if sym column not in source data
#   -C  Column rename mapping: "SrcCol:tgtCol,SrcCol2:tgtCol2"
#   -e  Path to .env file (default: .env)
#   -m  Write mode: "append" (default) or "overwrite"
#
# Examples:
#   ./scripts/batch-load.sh -f KwhConsumptionBlower78_1.csv -t energy -d 2026.04.17 -s BLOWER78_1 \
#     -C "TxnDate:date,TxnTime:timeWindow,Consumption:consumption"
#   ./scripts/batch-load.sh -f weather_data.csv.gz -t weather -d 2026.04.17 \
#     -C "Location:sym,Date_Time:dateTime,Temperature_C:temp,Humidity_pct:humidity,Precipitation_mm:precipitation,Wind_Speed_kmh:windSpeed"
#   ./scripts/batch-load.sh -f weather_data.csv -t weather -d 2026.04.17 -m overwrite

e_flag=".env"
delimiter=","
sym_val=""
col_map=""
mode="append"

print_usage() {
  echo "Usage: $0 -f <file> -t <table> -d <date> [-D delim] [-s sym] [-C colMap] [-e .env] [-m append|overwrite]"
  echo ""
  echo "  -f  Data file path (supports .gz/.zip/.zst compression)"
  echo "  -t  Target table name (must match schema)"
  echo "  -d  Partition date (YYYY.MM.DD)"
  echo "  -D  Delimiter (default: comma)"
  echo "  -s  Default sym value if not in source data"
  echo "  -C  Column mapping: \"SrcCol:tgtCol,SrcCol2:tgtCol2\""
  echo "  -e  Env file path (default: .env)"
  echo "  -m  Write mode: append (default) or overwrite"
}

while getopts 'f:t:d:D:s:C:e:m:h' flag; do
  case "${flag}" in
    f) file="${OPTARG}" ;;
    t) table="${OPTARG}" ;;
    d) date="${OPTARG}" ;;
    D) delimiter="${OPTARG}" ;;
    s) sym_val="${OPTARG}" ;;
    C) col_map="${OPTARG}" ;;
    e) e_flag="${OPTARG}" ;;
    m) mode="${OPTARG}" ;;
    h) print_usage; exit 0 ;;
    *) print_usage; exit 1 ;;
  esac
done

# ── Validation ──────────────────────────────────────────────────────────

if [ -z "$file" ] || [ -z "$table" ] || [ -z "$date" ]; then
  echo "ERROR: -f, -t, and -d are required."
  print_usage
  exit 1
fi

if [ ! -f "$file" ]; then
  echo "ERROR: File not found: $file"
  exit 1
fi

# Resolve to absolute path so q can find the file regardless of working directory
file="$(realpath "$file")"

# Validate date format (YYYY.MM.DD)
if ! echo "$date" | grep -qP '^\d{4}\.\d{2}\.\d{2}$'; then
  echo "ERROR: Invalid date format '$date'. Use YYYY.MM.DD (e.g., 2026.04.17)"
  exit 1
fi

# Validate mode
if [ "$mode" != "append" ] && [ "$mode" != "overwrite" ]; then
  echo "ERROR: Invalid mode '$mode'. Must be 'append' or 'overwrite'"
  exit 1
fi

# ── Source environment ──────────────────────────────────────────────────

if [ ! -f "$e_flag" ]; then
  echo "ERROR: Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

# Validate required env vars
for var in HDB_DIR SCHEMA_DIR PROCESS_LOG_DIR; do
  if [ -z "${!var}" ]; then
    echo "ERROR: $var not set. Check your .env file."
    exit 1
  fi
done

# ── Compressed file handling ────────────────────────────────────────────

actual_file="$file"
orig_file="$file"
tmp_file=""
stream_flag=""

cleanup() {
  if [ -n "$tmp_file" ] && [ -f "$tmp_file" ]; then
    rm -f "$tmp_file"
  fi
}
trap cleanup EXIT

if [[ "$file" == *.gz ]]; then
  base=$(basename "$file" .gz)
  tmp_file="/tmp/batch-$$-${base}"
  echo "Decompressing $file -> $tmp_file"
  gunzip -c "$file" > "$tmp_file"
  actual_file="$tmp_file"
elif [[ "$file" == *.zip ]]; then
  base=$(basename "$file" .zip)
  tmp_file="/tmp/batch-$$-${base}"
  echo "Decompressing $file -> $tmp_file"
  unzip -p "$file" > "$tmp_file"
  actual_file="$tmp_file"
elif [[ "$file" == *.zst ]]; then
  base=$(basename "$file" .zst)
  tmp_file="/tmp/batch-$$-${base}"
  echo "Decompressing $file -> $tmp_file"
  zstd -dc "$file" > "$tmp_file"
  actual_file="$tmp_file"
fi

# ── Build q args ────────────────────────────────────────────────────────

q_args="-file $actual_file -table $table -date $date -delimiter $delimiter"
q_args="$q_args -hdbDir $HDB_DIR -schemaDir $SCHEMA_DIR -mode $mode"
q_args="$q_args -origFile $orig_file -procName BATCH"

if [ -n "$sym_val" ]; then
  q_args="$q_args -sym $sym_val"
fi

if [ -n "$col_map" ]; then
  q_args="$q_args -colMap $col_map"
fi

if [ -n "$stream_flag" ]; then
  q_args="$q_args -stream 1"
fi

# ── Launch q batch loader ───────────────────────────────────────────────

echo "Starting batch load: table=$table date=$date file=$file mode=$mode"

q kdb-x-platform/batch.q $q_args < /dev/null 2>&1 | tee -a "$PROCESS_LOG_DIR/batch.log"
exit_code=${PIPESTATUS[0]}

if [ $exit_code -eq 0 ]; then
  echo ""
  echo "Batch load succeeded. Triggering HDB reload..."
  ./scripts/reload-hdb.sh -e "$e_flag"
else
  echo ""
  echo "Batch load FAILED (exit code $exit_code)"
  exit $exit_code
fi
