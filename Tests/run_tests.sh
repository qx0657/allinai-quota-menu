#!/bin/zsh
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/allinai-test-build.XXXXXX")"
trap 'rm -rf "${TEST_STAGE}"' EXIT

# Supply the async test entry instead of the app's blocking NSApplication event loop.
sed '/^#if !QUOTA_TESTING$/,$d' "${TEST_ROOT}/Sources/AllinAIQuotaMenu.swift" > "${TEST_STAGE}/tests.swift"
cat "${TEST_ROOT}/Tests/AllinAIQuotaTests.swift" >> "${TEST_STAGE}/tests.swift"
swiftc -parse-as-library -D QUOTA_TESTING "${TEST_STAGE}/tests.swift" -framework Security -o "${TEST_STAGE}/tests"
"${TEST_STAGE}/tests" "$@"
