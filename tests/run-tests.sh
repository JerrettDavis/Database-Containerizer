#!/usr/bin/env bash
set -euo pipefail

echo "[DEBUG] build.sh invoked (PID $$), args: $*"

echo
echo "==================== Database Containerizer CLI Tests ===================="
echo

# --------------------------------------------------------------------------------------
# Locate repo root (assumes tests/ is directly under repo root)
# --------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_SCRIPT="$REPO_ROOT/scripts/build.sh"
if [ ! -f "$BUILD_SCRIPT" ]; then
  echo "[FATAL] build.sh not found at: $BUILD_SCRIPT" >&2
  exit 1
fi

echo "[DEBUG] Using build script: $BUILD_SCRIPT"
BACKUP_DIR="$REPO_ROOT/backup"
mkdir -p "$BACKUP_DIR"

# Default URL for test backup (AdventureWorks)
DEFAULT_TEST_BACKUP_URL="https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak"

# --------------------------------------------------------------------------------------
# Simple test wrapper
# --------------------------------------------------------------------------------------
TEST_COUNT=0
FAIL_COUNT=0

run_test() {
  local name="$1"
  shift

  TEST_COUNT=$((TEST_COUNT + 1))

  echo
  echo "==================== TEST ${TEST_COUNT}: ${name} ===================="
  echo

  set +e
  "$@"
  local ec=$?
  set -e

  if [ $ec -eq 0 ]; then
    echo "[PASS] ${name}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[FAIL] ${name} (exit code $ec)"
  fi
}

# --------------------------------------------------------------------------------------
# TEST 1: Build with defaults (minimal parameters)
# --------------------------------------------------------------------------------------
test_build_defaults() {
  echo "[INFO] Running build.sh with minimal parameters..."

  pushd "$REPO_ROOT" >/dev/null

  set +e
  "$BUILD_SCRIPT" \
    --database_name="DefaultDb" \
    --database_backup_url="$DEFAULT_TEST_BACKUP_URL" \
    --version="1.0.0" \
    --tag="dbcontainerizer-test-defaults" \
    --use_insecure_ssl="yes" \
    --no_extract_artifacts
  local ec=$?
  set -e

  popd >/dev/null

  if [ $ec -ne 0 ]; then
    echo "docker build failed with exit code $ec" >&2
    return $ec
  fi

  return 0
}

# --------------------------------------------------------------------------------------
# TEST 2: Build with local backup file (auto-download if missing)
# --------------------------------------------------------------------------------------
test_build_local_backup() {
  local test_db_name="${TEST_DB_NAME:-TestDb}"
  local test_local_backup_file="${TEST_LOCAL_BACKUP_FILE:-${test_db_name}.bak}"
  local backup_path="$BACKUP_DIR/$test_local_backup_file"

  if [ ! -f "$backup_path" ]; then
    local backup_url="${TEST_BACKUP_URL:-$DEFAULT_TEST_BACKUP_URL}"
    echo "[INFO] Local backup '$backup_path' not found. Downloading from $backup_url..."

    set +e
    curl -L "$backup_url" -o "$backup_path"
    local curl_ec=$?
    set -e

    if [ $curl_ec -ne 0 ]; then
      echo "Failed to download test backup from $backup_url (exit code $curl_ec)." >&2
      return 1
    fi

    if [ ! -f "$backup_path" ]; then
      echo "Download appeared to succeed, but '$backup_path' still does not exist." >&2
      return 1
    fi

    echo "[INFO] Test backup downloaded to $backup_path"
  else
    echo "[INFO] Using existing local backup: $backup_path"
  fi

  pushd "$REPO_ROOT" >/dev/null

  set +e
  "$BUILD_SCRIPT" \
    --database_name="$test_db_name" \
    --database_backup_file="$test_local_backup_file" \
    --version="1.0.1" \
    --tag="dbcontainerizer-test-local-backup" \
    --use_insecure_ssl="yes" \
    --no_extract_artifacts
  local ec=$?
  set -e

  popd >/dev/null

  if [ $ec -ne 0 ]; then
    echo "docker build failed with exit code $ec" >&2
    return $ec
  fi

  return 0
}

# --------------------------------------------------------------------------------------
# TEST 3: Build with missing backup should fail
# --------------------------------------------------------------------------------------
test_build_missing_backup() {
  echo "[INFO] Running build.sh with missing backup file (expect failure)..."

  local missing_file="this_file_should_not_exist_$$.bak"

  pushd "$REPO_ROOT" >/dev/null

  set +e
  "$BUILD_SCRIPT" \
    --database_name="MissingDb" \
    --database_backup_file="$missing_file" \
    --version="1.0.2" \
    --tag="dbcontainerizer-test-missing-backup" \
    --use_insecure_ssl="yes" \
    --no_extract_artifacts
  local ec=$?
  set -e

  popd >/dev/null

  if [ $ec -eq 0 ]; then
    echo "Expected failure due to missing backup file, but build succeeded." >&2
    return 1
  else
    echo "[INFO] Build failed as expected with exit code $ec"
    return 0
  fi
}

# --------------------------------------------------------------------------------------
# Run tests
# --------------------------------------------------------------------------------------
run_test "Build with defaults (minimal parameters)" test_build_defaults
run_test "Build with local backup file"            test_build_local_backup
run_test "Build with missing backup should fail"   test_build_missing_backup

# --------------------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------------------
echo
echo "==================== SUMMARY ===================="
echo "Total tests:  $TEST_COUNT"
echo "Failed tests: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Some tests failed."
  exit 1
else
  echo "All tests passed."
  exit 0
fi
