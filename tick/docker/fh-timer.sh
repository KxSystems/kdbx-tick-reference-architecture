#!/bin/bash

# Start, stop or retune the feedhandler ingest timer without restarting the FH
# container. Source this file to expose the functions.
#
# Usage (from any directory):
#   source tick/docker/fh-timer.sh
#   start_fh_timer         # enable ingest at $FH_TIMER ms intervals (default 60000)
#   start_fh_timer 1000    # ...or at a custom interval
#   stop_fh_timer          # pause ingest
#
# The q client runs INSIDE the fh container, where the FH is on localhost, so
# nothing needs to be installed on the host. FH_PORT / FH_TIMER come from the
# environment or tick/docker/.env, same as compose.yaml.

_FH_COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -f "$_FH_COMPOSE_DIR/.env" ] && { set -a; . "$_FH_COMPOSE_DIR/.env"; set +a; }

_fh_send() {
  # printf, not echo: zsh's echo would interpret the backslashes
  printf '%s\n' "fh:hopen \`::${FH_PORT:-5014}; fh\"\\\\t $1\";exit 0" \
    | docker compose -f "$_FH_COMPOSE_DIR/compose.yaml" exec -T fh q
}

start_fh_timer() {
  local ms="${1:-${FH_TIMER:-60000}}"
  _fh_send "$ms" && echo "FH timer started at $ms ms"
}

stop_fh_timer() {
  _fh_send 0 && echo "FH timer stopped"
}
