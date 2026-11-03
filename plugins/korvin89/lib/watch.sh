# watch.sh — the polling loop behind korvin89 watchers. Source after gh.sh and
# gh_tmp_init. Run it as a background Bash call: it prints one line and exits,
# which wakes the session.
#
#   watch_loop <probe>   poll until the probe reports an event, print one line
#   watch_pid <file>     mark <file>'s directory as in use: write our pid there,
#                        if the directory exists (a watcher never creates one)
#   watch_release        remove that file if it still holds our pid; call it
#                        from the caller's EXIT trap
#
# The probe is a shell function. It runs in this shell, so it may keep state
# between polls, and it prints at most one line, tab-separated:
#   NOW   <event line>                  fire at once
#   WAIT  <fingerprint>  <event line>   fire once the fingerprint has not changed
#                                       for WATCH_QUIET seconds
#   HOT                                 nothing to report yet, but something is
#                                       in progress: keep the first gap
#   (nothing)                           nothing to report yet
# It returns non-zero when it could not look. The loop runs until the probe
# reports an event; there is no idle timeout.
#
# Settings, in seconds:
#   WATCH_INTERVAL      20     the first gap between polls
#   WATCH_MAX_INTERVAL  = WATCH_INTERVAL
#                       quiet polls double the gap up to this; WAIT and HOT
#                       bring it back to the first gap
#   WATCH_QUIET         60     the debounce for WAIT
# A probe that runs gh in child processes exports GH_AUTH_FLAG (watch_loop sets
# it to $GH_TMP/auth), so their auth failures reach the loop.
#
# Other lines it prints:
#   AUTH <message>     gh is not authenticated: exit 1 at once
#   ERROR <message>    five failed polls in a row: exit 1

WATCH_INTERVAL="${WATCH_INTERVAL:-20}"
WATCH_MAX_INTERVAL="${WATCH_MAX_INTERVAL:-$WATCH_INTERVAL}"
WATCH_QUIET="${WATCH_QUIET:-60}"
WATCH_PIDFILE=""

watch_pid() {
  if [ -d "${1%/*}" ]; then printf '%s\n' "$$" > "$1"; WATCH_PIDFILE="$1"; fi
}

watch_release() {
  [ -z "$WATCH_PIDFILE" ] || [ "$(cat "$WATCH_PIDFILE" 2>/dev/null)" != "$$" ] || rm -f "$WATCH_PIDFILE"
}

watch_loop() {
  local probe="$1" now gap line kind rest fp ev prev="" since=0 fails=0
  [ "$WATCH_MAX_INTERVAL" -ge "$WATCH_INTERVAL" ] || WATCH_MAX_INTERVAL="$WATCH_INTERVAL"
  gap="$WATCH_INTERVAL"
  export GH_AUTH_FLAG="$GH_TMP/auth"
  while :; do
    now="$(date +%s)"; kind=""
    if "$probe" > "$GH_TMP/probe.out" 2> "$GH_TMP/probe.err"; then
      fails=0
      line="$(head -n 1 "$GH_TMP/probe.out")"
      kind="${line%%$'\t'*}"
      case "$kind" in
        NOW)
          printf '%s\n' "${line#*$'\t'}"; return 0 ;;
        WAIT)
          rest="${line#*$'\t'}"; fp="${rest%%$'\t'*}"; ev="${rest#*$'\t'}"
          if [ "$fp" != "$prev" ]; then prev="$fp"; since="$now"; fi
          if [ $((now - since)) -ge "$WATCH_QUIET" ]; then printf '%s\n' "$ev"; return 0; fi
          gap="$WATCH_INTERVAL" ;;
        HOT)
          prev=""; gap="$WATCH_INTERVAL" ;;
        *)
          prev="" ;;
      esac
    else
      if [ -f "$GH_TMP/auth" ]; then
        printf 'AUTH %s\n' "$(tail -n 1 "$GH_TMP/probe.err")"; return 1
      fi
      fails=$((fails + 1))
      if [ "$fails" -ge 5 ]; then
        printf 'ERROR %s\n' "$(tail -n 1 "$GH_TMP/probe.err")"; return 1
      fi
    fi
    sleep "$gap"
    case "$kind" in
      WAIT|HOT) ;;
      *) gap=$((gap * 2)); [ "$gap" -le "$WATCH_MAX_INTERVAL" ] || gap="$WATCH_MAX_INTERVAL" ;;
    esac
  done
}
