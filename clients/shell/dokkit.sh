# The Dokkit client library for shell scripts. One file to source; needs only curl.
#
#     . ./dokkit.sh                          # reads DOKKIT_URL and DOKKIT_KEY; blank means off
#     dokkit_beat worker                     # from the main loop
#     dokkit_job nightly-purge ./purge.sh    # runs the command and reports how it went
#     dokkit_check queue-age degraded 14 "oldest item is 14 minutes old"
#     dokkit_metric queue.depth 7
#     dokkit_log error "Upload failed"
#
# Each call sends one line and waits at most five seconds, twice if the first try fails. A line
# that cannot be sent is dropped and the script carries on. A machine with the dokkit program on
# it can use `dokkit run` instead, which also keeps the last lines of output.

# Newlines and tabs become spaces first: BSD sed adds a newline of its own.
_dokkit_text() { printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# A number as JSON takes digits and a dot only; anything else would put fields into the line.
_dokkit_num() { case $1 in '' | *[!0-9.-]*) return 1 ;; esac; }

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
_dokkit_post() {
  printf 'url = "%s/api/v1/report"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: application/x-ndjson"\ndata-binary = "%s"\n' \
    "$(_dokkit_text "${DOKKIT_URL%/}")" "$(_dokkit_text "$DOKKIT_KEY")" "$(_dokkit_text "$1")" |
    curl -s -f -o /dev/null --max-time 5 -K -
}

_dokkit_send() {
  _dokkit_on || return 0
  _dokkit_line="{$1,\"host\":\"$(_dokkit_text "$(hostname)")\"}"
  _dokkit_post "$_dokkit_line" || _dokkit_post "$_dokkit_line" || true
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
dokkit_log() { _dokkit_send "\"type\":\"log\",\"level\":\"$(_dokkit_text "$1")\",\"msg\":\"$(_dokkit_text "${2:-}")\""; }

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
