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
# The endpoint answers with a small JSON object; anything larger is a broken or
# hostile upstream and must not be allowed to grow this process every poll.
MAX_RESPONSE_BYTES=$((64 * 1024))
# Bound on the free-form timestamp string before it is forwarded to QML.
MAX_TIMESTAMP_CHARS=64

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/barebitcoin-plugin.XXXXXX")" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT

# --- config path safety -----------------------------------------------------
# The directory is created privately (0700) and the default config is written
# to a temp file and published with O_EXCL semantics. A planted symlink or
# non-regular file at either path is refused instead of followed, so the
# first-run write can never create or overwrite a file outside this directory.
if [[ -L $CONFIG_DIR ]]; then
  echo '{"error":"config directory is a symlink"}' >&2
  exit 1
fi
mkdir -p -m 700 "$CONFIG_DIR" || exit 1

write_default_config() {
  local tmp
  if [[ -L $CONFIG_FILE ]]; then
    echo '{"error":"config path is a symlink"}' >&2
    return 1
  fi
  if [[ -e $CONFIG_FILE ]]; then
    if [[ ! -f $CONFIG_FILE ]]; then
      echo '{"error":"config path is not a regular file"}' >&2
      return 1
    fi
    return 0   # already configured; never rewritten
  fi
  tmp="$(mktemp "$CONFIG_DIR/.config.XXXXXX")" || return 1
  chmod 600 "$tmp"
  cat > "$tmp" <<'JSON'
{
  "upper_threshold_nok": null,
  "lower_threshold_nok": null,
  "poll_interval_seconds": 60
}
JSON
  # O_EXCL|O_CREAT (noclobber) fails when the path exists and never follows a
  # symlink, so it doubles as the proof that the destination is still free.
  if ! ( set -C; : > "$CONFIG_FILE" ) 2>/dev/null; then
    rm -f "$tmp"
    echo '{"error":"config path appeared while creating it"}' >&2
    return 1
  fi
  # Atomic replace; mv replaces a symlink at the destination rather than
  # following it, so the content lands in this directory.
  mv -f "$tmp" "$CONFIG_FILE"
}

write_default_config || exit 1

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

# Download at most MAX_RESPONSE_BYTES+1 bytes into a private temp file, then
# validate the expected schema in place. The body is never held in a shell
# variable, and it is only ever handed to QML as the bounded projection built
# by emit_bounded(). Exit codes: 0 ok, 1 request failed, 2 response exceeded
# the size cap, 3 response was not the expected schema.
fetch_price() { # $1 = body file to write
  local body="$1" curl_rc
  : > "$body"
  # head closes the pipe as soon as it holds one byte past the cap, aborting
  # curl's read from the socket; a file at the cap means the real response was
  # larger still.
  curl -fsS --max-time 10 -H "User-Agent: $USER_AGENT" "$PRICE_URL" 2>/dev/null \
    | head -c "$((MAX_RESPONSE_BYTES + 1))" > "$body"
  curl_rc=${PIPESTATUS[0]}
  if (( $(stat -c %s "$body") > MAX_RESPONSE_BYTES )); then
    : > "$body"
    return 2
  fi
  if (( curl_rc != 0 )); then
    : > "$body"
    return 1
  fi
  # Parse only the field the plugin consumes, and only as a finite number;
  # everything else in the body is ignored.
  if ! jq -e '(.price | type) == "number" and (.price | isfinite)' "$body" >/dev/null 2>&1; then
    : > "$body"
    return 3
  fi
  return 0
}

# The single line forwarded to QML: a projection of the validated body holding
# only the fields Feed.qml reads, with the free-form timestamp truncated. The
# raw upstream body is never echoed through.
emit_bounded() { # $1 = validated body file
  jq -c '
    {
      price: .price,
      bid: (if (.bid | type) == "number" and (.bid | isfinite) then .bid else null end),
      ask: (if (.ask | type) == "number" and (.ask | isfinite) then .ask else null end),
      timestamp: (if (.timestamp | type) == "string"
                  then (.timestamp[0:$n]) else null end)
    }
    | with_entries(select(.value != null))' --argjson n "$MAX_TIMESTAMP_CHARS" "$1"
}

# Always one immediate poll so the pill fills on shell start, then config pace.
sleep_for=0
while true; do
  (( sleep_for > 0 )) && sleep "$sleep_for"

  read -r upper lower sleep_for < <(read_config)
  [[ -n ${upper:-} && -n ${sleep_for:-} ]] || { upper=null; lower=null; sleep_for=60; }

  body="$TMP_DIR/price.json"
  rc=0
  fetch_price "$body" || rc=$?
  case $rc in
    0) ;;
    1) echo '{"error":"price request failed"}'; continue ;;
    2) echo '{"error":"price response exceeded the size cap"}'; continue ;;
    *) echo '{"error":"unexpected response shape"}'; continue ;;
  esac

  price="$(jq -r '.price' "$body" 2>/dev/null)"
  [[ -n ${price:-} ]] || { echo '{"error":"unexpected response shape"}'; continue; }

  check_cross "$price" "$upper" "$lower"
  line="$(emit_bounded "$body" 2>/dev/null)"
  [[ -n $line ]] || line='{"error":"unexpected response shape"}'
  printf '%s\n' "$line"
done
