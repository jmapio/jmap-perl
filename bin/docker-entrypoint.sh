#!/bin/bash
set -e

export JMAP_HOME="${JMAP_HOME:-/opt/jmap-perl}"
export JMAP_DATADIR="${JMAP_DATADIR:-/data}"
export JMAP_PORT="${JMAP_PORT:-9000}"
export BASEURL="${BASEURL:-http://localhost:$JMAP_PORT}"

mkdir -p "$JMAP_DATADIR"

# Raise the file-descriptor ceiling to the hard limit. The default soft 1024 is
# low for a socket per client plus a socketpair per backend child, and running
# out is not graceful: accept() returns EMFILE and the level-triggered event
# loop then spins at 100% CPU serving nobody.
if [ -n "${JMAP_NOFILE:-}" ]; then
  ulimit -n "$JMAP_NOFILE" 2>/dev/null || echo "warning: could not set ulimit -n to $JMAP_NOFILE" >&2
else
  hard=$(ulimit -Hn 2>/dev/null || echo 1024)
  [ "$hard" = "unlimited" ] && hard=65536
  ulimit -n "$hard" 2>/dev/null || true
fi
echo "file descriptor limit: $(ulimit -n)" >&2

# Initialize and migrate accounts DB
# Run as the unprivileged jmap user (see the Dockerfile).  A data directory
# from a root-run image is handed over first; JMAP_RUN_AS_ROOT=1 keeps the
# old behaviour.
if [ "$(id -u)" = "0" ] && [ -z "${JMAP_RUN_AS_ROOT:-}" ] && id jmap >/dev/null 2>&1; then
  if [ "$(stat -c %u "$JMAP_DATADIR")" != "$(id -u jmap)" ] \
     || [ -n "$(find "$JMAP_DATADIR" ! -user jmap -print -quit 2>/dev/null)" ]; then
    echo "handing $JMAP_DATADIR to the jmap user" >&2
    chown -R jmap:jmap "$JMAP_DATADIR"
  fi
  exec setpriv --reuid=jmap --regid=jmap --init-groups --inh-caps=-all \
    perl -I"$JMAP_HOME" "$JMAP_HOME/bin/jmap-proxy.pl"
fi
exec perl -I"$JMAP_HOME" "$JMAP_HOME/bin/jmap-proxy.pl"
