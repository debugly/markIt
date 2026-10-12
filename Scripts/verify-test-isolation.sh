#!/bin/bash
# Proves that an XCUITest run leaves the user's real preferences untouched.
#
# The app side already refuses to write to production defaults when
# --uitest-suite is passed, and refuses to reset without it. That is
# enforcement, not evidence. This script is the evidence: it snapshots the
# production store from outside the app process, runs the UI tests, and
# compares.
#
# Everything here is deliberately external. A test living inside the runner
# cannot answer the question -- the runner and the app are separate processes
# with separate UserDefaults caches, so a test that reads production
# defaults can be fooled by its own caching, and a test that writes to them to
# set up a fixture is risking the real data just to check it.
#
# Usage: Scripts/verify-test-isolation.sh [extra xcodebuild args...]

set -uo pipefail

PRODUCTION_SUITE="com.debugly.markit"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="/tmp/mk-isolation-check"

# The keys a test run would plausibly clobber. --uitest-reset deletes these
# four by name; the rest are anything the app persists about the user.
WATCHED_KEYS=(
  "MarkIt.Bookmarks"
  "MarkIt.RecentFiles"
  "MarkIt.LastOpenedFileBookmark"
  "MarkIt.LastOpenedFileURL"
  "MarkIt.PreviewStyle"
  "MarkIt.IsWebViewInspectEnabled"
  "MarkIt.WebDAVSecureVault"
  "WebDAVFolderConfigs"
  "WebDAVPendingDeletions"
)

snapshot() {
  # One line per watched key: name plus a digest of its value, so binary
  # blobs compare by content and not by plist formatting.
  for key in "${WATCHED_KEYS[@]}"; do
    local value
    value=$(defaults read "$PRODUCTION_SUITE" "$key" 2>/dev/null)
    local digest="<absent>"
    if [[ -n "$value" ]]; then
      digest=$(printf '%s' "$value" | shasum | cut -d' ' -f1)
    fi
    printf '%s=%s\n' "$key" "$digest"
  done
}

echo "==> snapshotting production suite ($PRODUCTION_SUITE)"
snapshot > /tmp/mk-isolation-before.txt
before_plist_hash=$(shasum "$HOME/Library/Preferences/$PRODUCTION_SUITE.plist" 2>/dev/null | cut -d' ' -f1)
echo "    plist sha: ${before_plist_hash:-<no plist>}"
sed 's/^/    /' /tmp/mk-isolation-before.txt

# Make sure a stale /Applications copy cannot be what gets exercised: the
# scheme builds and launches its own, but a leftover install is a confusing
# failure mode if something goes wrong later.
echo "==> running UI tests"
cd "$REPO" || exit 1
xcodebuild test \
  -project Markit.xcodeproj \
  -scheme Markit \
  -derivedDataPath "$DERIVED" \
  "$@" 2>&1 | tail -40
test_status=${PIPESTATUS[0]}

echo "==> snapshotting production suite again"
snapshot > /tmp/mk-isolation-after.txt
after_plist_hash=$(shasum "$HOME/Library/Preferences/$PRODUCTION_SUITE.plist" 2>/dev/null | cut -d' ' -f1)

echo "==> diff"
if diff -u /tmp/mk-isolation-before.txt /tmp/mk-isolation-after.txt; then
  diff_status=0
else
  diff_status=1
fi

# The whole plist is checked too, not just the keys we expected to matter:
# catching an unexpected write is the entire point.
if [[ "$before_plist_hash" == "$after_plist_hash" ]]; then
  plist_status=0
  echo "    plist unchanged: $after_plist_hash"
else
  plist_status=1
  echo "    plist CHANGED: ${before_plist_hash:-<none>} -> ${after_plist_hash:-<none>}"
fi

echo "==> test suites created by this run (should exist, proving isolation was used)"
ls -1 "$HOME/Library/Preferences/" 2>/dev/null | grep '^com\.debugly\.markit\.uitest\.' | head -5 || true
suite_count=$(ls -1 "$HOME/Library/Preferences/" 2>/dev/null | grep -c '^com\.debugly\.markit\.uitest\.' || true)
echo "    $suite_count suite(s)"

failed=0
if [[ $test_status -ne 0 ]]; then
  echo "FAIL: the UI tests themselves did not pass (exit $test_status)"
  failed=1
fi
if [[ $diff_status -ne 0 ]]; then
  echo "FAIL: a watched production key changed during the test run"
  failed=1
fi
if [[ $plist_status -ne 0 ]]; then
  echo "FAIL: the production plist was modified during the test run"
  failed=1
fi
if [[ "$suite_count" -eq 0 ]]; then
  echo "FAIL: no isolated suite was created -- the tests probably ran against production"
  failed=1
fi

if [[ $failed -eq 0 ]]; then
  echo "PASS: production defaults untouched, isolated suites used"
else
  echo "FAILED"
fi
exit $failed