#!/usr/bin/env bash
# Threshold watcher for io.github.katla50.barebitcoin.
#
# The QML side of the plugin spawns this script once with the plugin's config
# directory as its only argument and reads one JSON line per poll from its
# stdout. The script owns everything that should never run inside the
# long-lived shell process: reading ~/.config/barebitcoin-plugin/config.json,
# curling the public price endpoint, crossing detection with persisted state,
# and notify-send. Read-only: the only network call is a single GET.
set -u

CONFIG_DIR="${1:?usage: price-watch.sh <config-dir>}"
PRICE_URL="https://api.bb.no/v1/price/nok"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_FILE="$CONFIG_DIR/.state.json"
USER_AGENT="io.github.katla50.barebitcoin/1.0 (Omarchy plugin)"

mkdir -p "$CONFIG_DIR"

# Default config on first run so the user has something concrete to edit.
if [[ ! -f $CONFIG_FILE ]]; then
  cat > "$CONFIG_FILE" <<'JSON'
{
  "upper_threshold_nok": null,
  "lower_threshold_nok": null,
  "poll_interval_seconds": 60
}
JSON
fi

read_config() {
  jq -r '
    [
      (.upper_threshold_nok // null | tostring),
      (.lower_threshold_nok // null | tostring),
      ([.poll_interval_seconds // 60, 30] | max | tostring)
    ] | @tsv' "$CONFIG_FILE" 2>/dev/null
}

read_state() { # $1 = key, prints value or empty
  [[ -f $STATE_FILE ]] || return 0
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null
}

write_state() { # $1 = side ("upper"|"lower"), writes atomically
  local tmp
  tmp=$(mktemp "$CONFIG_DIR/.state.XXXXXX")
  printf '{"side":"%s"}\n' "$1" > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

notify_cross() { # $1 = direction, $2 = threshold, $3 = price
  command -v notify-send >/dev/null 2>&1 || return 0
  local title body
  title="BTC/NOK $1 terskel nådd"
  body=$(printf "Prisen er nå %s NOK (terskel: %s NOK) hos Bare Bitcoin." \
    "$(numfmt --grouping "${3%.*}")" "$(numfmt --grouping "${2%.*}")")
  notify-send --app-name="Bare Bitcoin Prisvarsel" --icon=bitcoin "$title" "$body" || true
}

check_cross() { # $1 = price, $2 = upper, $3 = lower
  local price="$1" upper="$2" lower="$3" side
  side=$(read_state side)

  if [[ $upper != null && -n $upper ]] && awk -v a="$price" -v b="$upper" 'BEGIN{exit !(a+0 >= b+0)}'; then
    [[ $side != upper ]] && notify_cross "øvre" "$upper" "$price"
    [[ $side != upper ]] && write_state upper
    return
  fi
  if [[ $lower != null && -n $lower ]] && awk -v a="$price" -v b="$lower" 'BEGIN{exit !(a+0 <= b+0)}'; then
    [[ $side != lower ]] && notify_cross "nedre" "$lower" "$price"
    [[ $side != lower ]] && write_state lower
    return
  fi
  # Back in the neutral band between the thresholds: re-arm both sides.
  [[ -n $side ]] && write_state ""
}

# Always one immediate poll so the pill fills on shell start, then config pace.
sleep_for=0
while true; do
  (( sleep_for > 0 )) && sleep "$sleep_for"

  read -r upper lower sleep_for < <(read_config)
  [[ -n ${upper:-} && -n ${sleep_for:-} ]] || { upper=null; lower=null; sleep_for=60; }

  response=$(curl -fsS --max-time 10 -H "User-Agent: $USER_AGENT" "$PRICE_URL" 2>/dev/null)
  if [[ -z ${response:-} ]]; then
    echo '{"error":"price request failed"}'
    continue
  fi

  price=$(jq -r '.price // empty' <<<"$response" 2>/dev/null)
  if [[ -z ${price:-} ]]; then
    echo '{"error":"unexpected response shape"}'
    continue
  fi

  check_cross "$price" "$upper" "$lower"
  echo "$response"
done
