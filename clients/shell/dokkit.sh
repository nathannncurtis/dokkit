# The Dokkit client library for shell scripts. One file to source; needs only curl.
#
#     . ./dokkit.sh                          # reads DOKKIT_URL and DOKKIT_KEY; blank means off
#     dokkit_beat worker                     # from the main loop
#     dokkit_job nightly-purge ./purge.sh    # runs the command and reports how it went
#     dokkit_check queue-age degraded 14 "oldest item is 14 minutes old"
#     dokkit_metric queue.depth 7
#     dokkit_log error "Upload failed"
#     dokkit_capture UploadError "Upload failed"
#
# Each call sends one line and waits at most five seconds, twice if the first try fails (an error report is tried again only if curl could not connect). A line
# that cannot be sent is dropped and the script carries on. A machine with the dokkit program on
# it can use `dokkit run` instead, which also keeps the last lines of output.

# Newlines and tabs become spaces first: BSD sed adds a newline of its own. Other control
# characters (U+0001 to U+001F) are dropped so the line is always valid JSON.
_dokkit_text() { printf '%s' "$1" | tr '\n\t' '  ' | tr -d '\000-\010\013-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# A number as JSON: -?digits[.digits], no leading zero; anything else would break the line or add fields.
_dokkit_num() { case $1 in '' | *[!0-9.-]* | ?*-* | *.*.* | - | .* | -.* | *. | 0[0-9]* | -0[0-9]*) return 1 ;; esac; }

# On, unless blank, or plain http to a host that is not this machine.
_dokkit_on() {
  [ -n "${DOKKIT_URL:-}" ] && [ -n "${DOKKIT_KEY:-}" ] || return 1
  case $DOKKIT_URL in
    http://localhost | http://localhost[:/]* | http://127.0.0.1 | http://127.0.0.1[:/]* | 'http://[::1]'*) ;;
    http://*)
      [ "${DOKKIT_INSECURE:-}" = 1 ] && return 0
      [ -n "${_dokkit_warned:-}" ] || echo "dokkit: http:// address to a non-local host; set DOKKIT_INSECURE=1 to allow it. Staying off." >&2
      _dokkit_warned=1
      return 1
      ;;
  esac
}

# The key and the body go to curl on its standard input, so ps never shows them.
# _dokkit_post <line> <batch id> _ <path> <content type> [line sent ahead of it]; report bodies of 1 KB or more are gzipped if gzip exists
_dokkit_post() {
  local body=$1 data tmp= code
  [ -z "${6:-}" ] || body="$6
$1"
  data="data-binary = \"$(_dokkit_text "$1")\""
  [ -z "${6:-}" ] || data="data-binary = \"$(_dokkit_text "$6")\\n$(_dokkit_text "$1")\""
  if [ "${4:-/api/v1/report}" = /api/v1/report ] && [ "${#body}" -ge 1024 ] && command -v gzip >/dev/null 2>&1 && tmp=$(mktemp 2>/dev/null); then
    if printf '%s' "$body" | gzip -c >"$tmp" 2>/dev/null; then
      data=$tmp
      ! command -v cygpath >/dev/null 2>&1 || data=$(cygpath -m "$tmp")
      data="header = \"Content-Encoding: gzip\"
data-binary = \"@$(_dokkit_text "$data")\""
    else
      rm -f "$tmp"
      tmp=
    fi
  fi
  printf 'url = "%s%s"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: %s"\nheader = "Dokkit-Batch: %s"\n%s\n' \
    "$(_dokkit_text "${DOKKIT_URL%/}")" "${4:-/api/v1/report}" "$(_dokkit_text "$DOKKIT_KEY")" "${5:-application/x-ndjson}" "$2" "$data" |
    curl -s -f -o /dev/null --max-time 5 -K -
  code=$?
  [ -z "$tmp" ] || rm -f "$tmp"
  return "$code"
}

# _dokkit_fit <escaped text> <bytes the rest of the line takes>
_dokkit_fit() {
  local text=$1 room tail
  [ "${#text}" -gt 16000 ] || { printf '%s' "$text"; return 0; }
  room=$((65536 - $2 - 6))
  [ "$(printf '%s' "$text" | wc -c)" -le "$((room + 6))" ] && { printf '%s' "$text"; return 0; }
  # cut -b may leave half a character at the end; the sed drops it, and a lead byte with it
  text=$(printf '%s' "$text" | LC_ALL=C cut -b "1-$room" | LC_ALL=C sed -e "s/[$(printf '\300')-$(printf '\377')][$(printf '\200')-$(printf '\277')]*\$//")
  tail=${text##*[!\\]}
  [ $((${#tail} % 2)) -eq 0 ] || text=${text%?}
  printf '%s [cut]' "$text"
}

# _dokkit_send <fields> [path] [content type]
_dokkit_send() {
  _dokkit_on || return 0
  local line id ahead= env= code
  case ${DOKKIT_ENV:-production} in production) ;; *) env=",\"environment\":\"$(_dokkit_text "$DOKKIT_ENV")\"" ;; esac
  line="{$1,\"host\":\"$(_dokkit_text "$(hostname)")\"$([ "${2:-}" = /api/v1/errors ] || printf '%s' "$env")}"
  id=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/')
  if [ -n "${DOKKIT_VERSION:-}" ] && [ "${DOKKIT_ANNOUNCE_VERSION:-1}" != 0 ] && [ -z "${_dokkit_announced:-}" ] && [ -z "${2:-}" ]; then
    _dokkit_announced=1
    ahead="{\"type\":\"deploy\",\"version\":\"$(_dokkit_text "$DOKKIT_VERSION")\",\"host\":\"$(_dokkit_text "$(hostname)")\"$env}"
  fi
  _dokkit_post "$line" "$id" "" "${2:-}" "${3:-}" "$ahead" && return 0
  code=$?
  # An error report is repeated only if curl never connected (6, 7); a timeout or 5xx may have been stored, and the server cannot tell a repeat
    [ "${2:-}" != /api/v1/errors ] || case $code in 6 | 7) ;; *) return 0 ;; esac
  _dokkit_post "$line" "$id" "" "${2:-}" "${3:-}" "$ahead" || true
}

# dokkit_deploy <version>   Sends a deploy line now. The server records it only when the version changed.
dokkit_deploy() {
  [ -n "${1:-}" ] || return 0
  _dokkit_announced=1
  _dokkit_send "\"type\":\"deploy\",\"version\":\"$(_dokkit_text "$1")\""
}

# dokkit_stats <file or JSON object>   Sends a stats document.
dokkit_stats() {
  local doc=$1
  [ ! -f "$1" ] || doc=$(cat "$1") || return 0
  doc=$(printf '%s' "$doc" | tr '\n\t' '  ' | tr -d '\000-\010\013-\037')
  doc=${doc#"${doc%%[! ]*}"}
  doc=${doc%"${doc##*[! ]}"}
  case $doc in '{'*'}') _dokkit_send "\"type\":\"stats\",\"document\":$doc" ;; esac
}

# dokkit_beat <name> [every seconds]
dokkit_beat() {
  _dokkit_num "${2:-60}" || return 0
  _dokkit_send "\"type\":\"beat\",\"name\":\"$(_dokkit_text "$1")\",\"every_seconds\":${2:-60}"
}

# dokkit_check <name> <ok|degraded|down> [value] [note]
dokkit_check() {
  case $2 in ok | degraded | down) ;; *) return 0 ;; esac
  [ -z "${3:-}" ] || _dokkit_num "$3" || return 0
  _dokkit_send "\"type\":\"custom\",\"check\":\"$(_dokkit_text "$1")\",\"state\":\"$2\"${3:+,\"value\":$3}${4:+,\"note\":\"$(_dokkit_text "$4")\"}"
}

# dokkit_metric <name> <value> [unit]
dokkit_metric() {
  _dokkit_num "${2:-}" || return 0
  _dokkit_send "\"type\":\"metric\",\"name\":\"$(_dokkit_text "$1")\",\"value\":$2${3:+,\"unit\":\"$(_dokkit_text "$3")\"}"
}

# dokkit_log <level> <message>
dokkit_log() {
  local level
  level=$(_dokkit_text "$1")
  _dokkit_send "\"type\":\"log\",\"level\":\"$level\",\"msg\":\"$(_dokkit_fit "$(_dokkit_text "${2:-}")" $((${#level} + 600)))\""
}

# dokkit_capture <type> <message>   Sends an error. The type is its name, such as UploadError.
# The message is not sent; a shell script has no stack, so the report carries none.
dokkit_capture() {
  _dokkit_send "\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$(_dokkit_text "${1:-Error}")\",\"handled\":true,\"frames\":[]${DOKKIT_ENV:+,\"environment\":\"$(_dokkit_text "$DOKKIT_ENV")\"}" /api/v1/errors application/json
}

# dokkit_job <name> <command...>   Returns what the command returns.
dokkit_job() {
  local job code began took event
  job="\"type\":\"job\",\"name\":\"$(_dokkit_text "$1")\",\"run\":\"$(date +%s)-$$-$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')${RANDOM:-}\""
  shift
  began=$(date +%s)
  _dokkit_send "$job,\"event\":\"start\""
  "$@" && code=0 || code=$?
  took=$((($(date +%s) - began) * 1000))
  if [ "$code" -eq 0 ]; then event=ok; else event=fail; fi
  _dokkit_send "$job,\"event\":\"$event\",\"exit_code\":$code,\"duration_ms\":$took"
  return "$code"
}
