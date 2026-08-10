#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SELFTEST_BIN="$REPO_ROOT/.build/kai-installer-selftest"

mkdir -p "$REPO_ROOT/.build"
swiftc \
  -parse-as-library \
  "$REPO_ROOT"/Sources/KAIInstallerCore/*.swift \
  "$REPO_ROOT/Tests/KAIInstallerCoreTests/KAIInstallerTests.swift" \
  -o "$SELFTEST_BIN"
"$SELFTEST_BIN"
