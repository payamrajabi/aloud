#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aloud-licensing.XXXXXX")
trap 'rm -rf "$TASK_TMP"' EXIT
node "$TASK_ROOT/Tests/licensing/issue-fixtures.mjs" > "$TASK_TMP/fixtures.json"
swiftc -D LICENSING_TESTS -module-cache-path "$TASK_TMP/module-cache" \
  "$TASK_ROOT/Sources/ReadAloud/Licensing.swift" "$TASK_ROOT/Tests/licensing/main.swift" \
  -o "$TASK_TMP/licensing-tests"
"$TASK_TMP/licensing-tests" "$TASK_TMP/fixtures.json"
