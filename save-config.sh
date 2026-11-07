#!/usr/bin/env bash
# Write ~/.config/barebitcoin-plugin/config.json from the panel's form.
#
# Called by Panel.qml as: save-config.sh <config-dir> <upper> <lower> <interval>
# where a threshold argument is a number, or "null"/"" to disable that side.
# Writes atomically and keeps the file schema price-watch.sh expects.
set -eu

DIR="${1:?usage: save-config.sh <config-dir> <upper|-> <lower|-> <interval>}"
UPPER="${2:-}"
LOWER="${3:-}"
INTERVAL="${4:-60}"
CONFIG="$DIR/config.json"

is_number() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
threshold() { # echoes a JSON number or the literal null
  case "$1" in
    ''|'-'|null|av|av|off) echo "null" ;;
    *) is_number "$1" || { echo "invalid threshold: $1" >&2; exit 2; }
       echo "$1" ;;
  esac
}

upper=$(threshold "$UPPER") || exit 2
lower=$(threshold "$LOWER") || exit 2

# The poll interval is user-editable here but never below the 30 s floor.
case "$INTERVAL" in
  ''|*[!0-9]*) INTERVAL=60 ;;
esac
(( INTERVAL < 30 )) && INTERVAL=30

mkdir -p "$DIR"
tmp=$(mktemp "$DIR/.config.XXXXXX")
trap 'rm -f "$tmp"' EXIT

jq -n \
  --argjson upper "$upper" \
  --argjson lower "$lower" \
  --argjson interval "$INTERVAL" \
  '{upper_threshold_nok: $upper, lower_threshold_nok: $lower, poll_interval_seconds: $interval}' \
  > "$tmp"
mv -f "$tmp" "$CONFIG"
trap - EXIT
echo "saved"
