#!/bin/bash
# Run JMAP TestSuite against the proxy (or directly against Cyrus) and save results
# Usage: ./bin/run-jmap-tests.sh [--direct] [test-path...]
#   --direct  : test against Cyrus JMAP natively (bypasses proxy)
#   No args   : run all suites via proxy

set -e

DATADIR="${JMAP_DATADIR:-/tmp/jmap-proxy-test}"
OUTFILE="/tmp/jmap-test-results.txt"
TESTSUITE="${JMAP_TESTSUITE:-/Users/brong/src/JMAP-TestSuite}"

DIRECT=0
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--direct" ]; then
    DIRECT=1
  else
    ARGS+=("$arg")
  fi
done

if [ "$DIRECT" = "1" ]; then
  ADAPTER="$DATADIR/cyrus-direct-config.json"
  OUTFILE="/tmp/jmap-cyrus-direct-results.txt"
else
  ADAPTER="$DATADIR/test-config.json"
fi

if [ ! -f "$ADAPTER" ]; then
  echo "Config not found: $ADAPTER"
  echo "Run bin/restart-test-proxy.sh first."
  exit 1
fi

cd "$TESTSUITE"

if [ "${#ARGS[@]}" -eq 0 ]; then
  TESTS="t/Email/ t/Mailbox/ t/Thread/ t/Calendar/ t/CalendarEvent/ t/AddressBook/ t/ContactCard/ t/Identity/ t/VacationResponse/ t/Quota/ t/Principal/ t/SearchSnippet/ t/MDN/ t/EmailSubmission/"
else
  TESTS="${ARGS[*]}"
fi

echo "Running: prove -lr $TESTS"
echo "Output: $OUTFILE"

JMAP_SERVER_ADAPTER_FILE="$ADAPTER" prove -lr $TESTS 2>&1 | tee "$OUTFILE"

echo ""
echo "=== SUMMARY ==="
echo "Results saved to $OUTFILE"
grep -E '(^Files|Result:|Wstat:)' "$OUTFILE" || true
