#!/bin/bash
# Run JMAP TestSuite against the proxy and save results
# Usage: ./bin/run-jmap-tests.sh [test-path...]
#   No args = run all Email/Mailbox/Thread tests
#   Args = run specific test files

set -e

OUTFILE="/tmp/jmap-test-results.txt"
ADAPTER="/tmp/jmap-proxy-test/test-config.json"
TESTSUITE="${JMAP_TESTSUITE:-/Users/brong/src/JMAP-TestSuite}"

cd "$TESTSUITE"

if [ $# -eq 0 ]; then
  TESTS="t/Email/ t/Mailbox/ t/Thread/ t/Calendar/ t/CalendarEvent/ t/AddressBook/ t/ContactCard/"
else
  TESTS="$@"
fi

echo "Running: prove -lr $TESTS"
echo "Output: $OUTFILE"

JMAP_SERVER_ADAPTER_FILE="$ADAPTER" prove -lr $TESTS 2>&1 | tee "$OUTFILE"

echo ""
echo "=== SUMMARY ==="
echo "Results saved to $OUTFILE"
grep -E '(^Files|Result:|Wstat:)' "$OUTFILE" || true
