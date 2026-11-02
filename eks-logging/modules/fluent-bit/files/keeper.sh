#!/bin/sh
# log-keeper: hard-links every container log file into $KEEP the moment it appears, so the
# data outlives the kubelet deleting the original (eviction, force delete, rotation cleanup).
# A hard link is a second name for the same file: appends show up in it, and the data stays
# until the last name is removed.
#
# Links whose original is gone (link count 1) are removed TTL_MINUTES after the deletion (the
# unlink updates the inode's ctime), or earlier, oldest first, when orphaned data exceeds
# KEEP_MAX_MB. Hard links only work within one filesystem and one mount, so /var/log is
# mounted as a single volume and $KEEP lives inside it.
set -u

SRC=/var/log/pods
KEEP=/var/log/keep
TTL_MINUTES=${TTL_MINUTES:-10}
KEEP_MAX_MB=${KEEP_MAX_MB:-1024}
mkdir -p "$KEEP"

# $1: a live container log, /var/log/pods/<ns>_<pod>_<uid>/<container>/<restart>.log.
# Rotated names (0.log.<timestamp>) are the same inode as an earlier 0.log, already linked.
link_one() {
  case "$1" in "$SRC"/*/*/*.log) ;; *) return 0 ;; esac
  ino=$(stat -c %i "$1" 2>/dev/null) || return 0
  rel=${1#"$SRC"/}
  dir="$KEEP/${rel%/*}"
  [ -e "$dir/$ino.log" ] && return 0
  mkdir -p "$dir" && ln "$1" "$dir/$ino.log" 2>/dev/null && echo "kept $rel as $ino.log"
}

scan() {
  for f in "$SRC"/*/*/*.log; do [ -f "$f" ] && link_one "$f"; done
}

# Orphans are the only kept files that cost disk space: live ones share their blocks with
# /var/log/pods.
orphan_mb() {
  find "$KEEP" -type f -links 1 -printf '%s\n' | awk '{s += $1} END {print int(s / 1048576)}'
}

cap_orphans() {
  while [ "$(orphan_mb)" -gt "$KEEP_MAX_MB" ]; do
    oldest=$(find "$KEEP" -type f -links 1 -printf '%C@ %p\n' | sort -n | head -1 | cut -d' ' -f2-)
    [ -n "$oldest" ] || break
    rm -f "$oldest" && echo "over ${KEEP_MAX_MB}MB, dropped $oldest"
  done
}

scan

# Event-driven path: link within milliseconds of the runtime creating the file. -r adds
# watches for new pod directories; a file created before its directory's watch exists is
# caught by scanning that directory on its create event.
inotifywait -m -r -q -e create -e moved_to --format '%w%f' "$SRC" | while read -r path; do
  if [ -d "$path" ]; then
    for f in "$path"/*.log "$path"/*/*.log; do [ -f "$f" ] && link_one "$f"; done
  else
    link_one "$path"
  fi
done &

# Safety net for anything the watcher missed, and garbage collection every 30 seconds.
n=0
while true; do
  sleep 1
  scan
  n=$((n + 1))
  if [ $((n % 30)) -eq 0 ]; then
    find "$KEEP" -type f -links 1 -cmin +"$TTL_MINUTES" -print -delete | sed 's/^/expired /'
    cap_orphans
    find "$KEEP" -mindepth 1 -type d -empty -delete
  fi
done
