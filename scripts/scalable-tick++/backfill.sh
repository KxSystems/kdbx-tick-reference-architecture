#!/bin/bash

# Backfill HDB with sample data across multiple dates.
# Loads energy (3 blower CSVs) and weather data into date partitions.
#
# Usage:
#   ./scripts/backfill.sh                    # backfill 2026.04.11 - 2026.04.17
#   ./scripts/backfill.sh -s 2026.04.01      # custom start date
#   ./scripts/backfill.sh -s 2026.04.15 -n 3 # 3 days from start
#   ./scripts/backfill.sh -e /path/.env      # custom env file

e_flag=".env"
start_date=""
num_days=7

while getopts 's:n:e:h' flag; do
  case "${flag}" in
    s) start_date="${OPTARG}" ;;
    n) num_days="${OPTARG}" ;;
    e) e_flag="${OPTARG}" ;;
    h)
      echo "Usage: $0 [-s start_date] [-n num_days] [-e .env]"
      echo "  -s  Start date (YYYY.MM.DD, default: 7 days ago)"
      echo "  -n  Number of days to backfill (default: 7)"
      echo "  -e  Env file path (default: .env)"
      exit 0
      ;;
    *) exit 1 ;;
  esac
done

# Source env
if [ ! -f "$e_flag" ]; then
  echo "ERROR: Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

DATA_DIR="${SAMPLE_DATA:-$ROOT_DIR/samples/data}/structured"

# Default start date: num_days ago
if [ -z "$start_date" ]; then
  start_date=$(date -d "-${num_days} days" +%Y.%m.%d)
fi

# Validate date format
if ! echo "$start_date" | grep -qP '^\d{4}\.\d{2}\.\d{2}$'; then
  echo "ERROR: Invalid start date '$start_date'. Use YYYY.MM.DD"
  exit 1
fi

# Convert YYYY.MM.DD to YYYY-MM-DD for date arithmetic
start_iso="${start_date//./-}"

echo "═══════════════════════════════════════════════════════════"
echo " Backfill: $num_days days starting $start_date"
echo " Data dir: $DATA_DIR"
echo " HDB dir:  $HDB_DIR"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Energy CSV files and their sym values
energy_files=(
  "KwhConsumptionBlower78_1.csv:BLOWER78_1"
  "KwhConsumptionBlower78_2.csv:BLOWER78_2"
  "KwhConsumptionBlower78_3.csv:BLOWER78_3"
)

energy_colmap="TxnDate:date,TxnTime:timeWindow,Consumption:consumption"
weather_colmap="Location:sym,Date_Time:dateTime,Temperature_C:temp,Humidity_pct:humidity,Precipitation_mm:precipitation,Wind_Speed_kmh:windSpeed"

total=0
failed=0

for i in $(seq 0 $((num_days - 1))); do
  dt=$(date -d "$start_iso + $i days" +%Y.%m.%d)
  echo "── Date: $dt ──────────────────────────────────────────────"

  # Load each energy blower file
  for entry in "${energy_files[@]}"; do
    csv="${entry%%:*}"
    sym="${entry##*:}"
    fp="$DATA_DIR/$csv"

    if [ ! -f "$fp" ]; then
      echo "  SKIP  energy ($sym) — file not found: $fp"
      continue
    fi

    echo -n "  LOAD  energy ($sym) ... "
    output=$(./scripts/batch-load.sh -f "$fp" -t energy -d "$dt" -s "$sym" \
      -C "$energy_colmap" -e "$e_flag" 2>&1)

    if [ $? -eq 0 ]; then
      echo "OK"
      total=$((total + 1))
    else
      echo "FAILED"
      echo "$output" | tail -3
      failed=$((failed + 1))
    fi
  done

  # Load weather data
  weather_fp="$DATA_DIR/weather_data.csv"
  if [ -f "$weather_fp" ]; then
    echo -n "  LOAD  weather ... "
    output=$(./scripts/batch-load.sh -f "$weather_fp" -t weather -d "$dt" \
      -C "$weather_colmap" -e "$e_flag" 2>&1)

    if [ $? -eq 0 ]; then
      echo "OK"
      total=$((total + 1))
    else
      echo "FAILED"
      echo "$output" | tail -3
      failed=$((failed + 1))
    fi
  else
    echo "  SKIP  weather — file not found: $weather_fp"
  fi

  echo ""
done

echo "═══════════════════════════════════════════════════════════"
echo " Backfill complete: $total loaded, $failed failed"
echo "═══════════════════════════════════════════════════════════"

[ $failed -eq 0 ] && exit 0 || exit 1
