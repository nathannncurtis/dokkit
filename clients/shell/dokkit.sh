# The Dokkit client library for shell scripts. One file to source; needs only curl.
#
#     . ./dokkit.sh                          # reads DOKKIT_URL and DOKKIT_KEY; blank means off
#     dokkit_beat worker                     # from the main loop
#     dokkit_job nightly-purge ./purge.sh    # runs the command and reports how it went
#     dokkit_check queue-age degraded 14 "oldest item is 14 minutes old"
#     dokkit_metric queue.depth 7
#     dokkit_log error "Upload failed"
#
# Each call sends one line and waits at most five seconds. A line that cannot be sent is
# dropped and the script carries on. A machine with the dokkit program on it can use
# `dokkit run` instead, which also keeps the last lines of output.

_dokkit_text() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  '; }

_dokkit_send() {
  [ -n "$DOKKIT_URL" ] && [ -n "$DOKKIT_KEY" ] || return 0
  curl -s -o /dev/null --max-time 5 -X POST "${DOKKIT_URL%/}/api/v1/report" \
    -H "Authorization: Bearer $DOKKIT_KEY" -H "Content-Type: application/x-ndjson" \
    --data-binary "{$1,\"host\":\"$(_dokkit_text "$(hostname)")\"}" || true
}

# dokkit_beat <name> [every seconds]
dokkit_beat() { _dokkit_send "\"type\":\"beat\",\"name\":\"$(_dokkit_text "$1")\",\"every_seconds\":${2:-60}"; }

# dokkit_check <name> <ok|degraded|down> [value] [note]
dokkit_check() {
  _dokkit_send "\"type\":\"custom\",\"check\":\"$(_dokkit_text "$1")\",\"state\":\"$2\"${3:+,\"value\":$3}${4:+,\"note\":\"$(_dokkit_text "$4")\"}"
}

# dokkit_metric <name> <value> [unit]
dokkit_metric() { _dokkit_send "\"type\":\"metric\",\"name\":\"$(_dokkit_text "$1")\",\"value\":$2${3:+,\"unit\":\"$(_dokkit_text "$3")\"}"; }

# dokkit_log <level> <message>
dokkit_log() { _dokkit_send "\"type\":\"log\",\"level\":\"$1\",\"msg\":\"$(_dokkit_text "$2")\""; }

# dokkit_job <name> <command...>   Returns what the command returns.
dokkit_job() {
  _dokkit_job="\"type\":\"job\",\"name\":\"$(_dokkit_text "$1")\",\"run\":\"$(date +%s)-$$\""
  shift
  _dokkit_began=$(date +%s)
  _dokkit_send "$_dokkit_job,\"event\":\"start\""
  "$@"
  _dokkit_code=$?
  _dokkit_took=$((($(date +%s) - _dokkit_began) * 1000))
  if [ "$_dokkit_code" -eq 0 ]; then _dokkit_event=ok; else _dokkit_event=fail; fi
  _dokkit_send "$_dokkit_job,\"event\":\"$_dokkit_event\",\"exit_code\":$_dokkit_code,\"duration_ms\":$_dokkit_took"
  return "$_dokkit_code"
}
