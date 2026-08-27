#!/bin/bash
# Headless test runner for herdr.nvim.
# Runs every tests/F0*.lua under a minimal init and expects "PASS: F0XX" output.
set -u
cd "$(dirname "$0")"

# macOS may lack coreutils `timeout`; fall back to gtimeout or a perl watchdog.
if command -v timeout >/dev/null 2>&1; then
  run_with_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  run_with_timeout() { gtimeout "$@"; }
else
  run_with_timeout() {
    local secs=$1; shift
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$secs" "$@"
  }
fi

# Per-test watchdog. Generous on purpose: these tests spawn dozens of real herdr
# subprocesses and wait on real uv timers, and on a loaded machine a round trip
# that normally takes 10ms can take seconds. The watchdog is here to catch a HANG
# (a wedged in-flight guard, a never-delivered callback), not to police runtime -
# the whole suite still finishes in well under a minute when the box is idle.
TEST_TIMEOUT=${TEST_TIMEOUT:-45}

pass=0
fail=0
failed=""
retried=""

shopt -s nullglob
test_files=(tests/F0*.lua)
shopt -u nullglob

if [ ${#test_files[@]} -eq 0 ]; then
  echo "No test files found (tests/F0*.lua)"
  exit 1
fi

for test_file in "${test_files[@]}"; do
  id=$(basename "$test_file" | sed 's/_test\.lua$//; s/\.lua$//')

  # A failing `luafile` assertion does NOT make nvim exit non-zero, because the
  # trailing -c "qa!" runs regardless. So the chunk is loaded under xpcall and an
  # error is turned into an explicit `:cq 1`. Three independent failure signals
  # are kept, and all three must be satisfied to pass:
  #   1. exit status (assertion error -> cq 1; hang -> watchdog)
  #   2. the "PASS: $id" line (a test that prints nothing fails even at exit 0)
  #   3. the traceback printed on stderr, for diagnosis
  run_lua="lua local ok, err = xpcall(dofile, debug.traceback, '$test_file') if not ok then io.stderr:write('TEST ERROR: ' .. tostring(err) .. '\\n') vim.cmd('cq 1') end"
  output=$(run_with_timeout "$TEST_TIMEOUT" nvim --headless -u tests/minimal-init.lua -c "$run_lua" -c "qa!" 2>&1)
  status=$?

  # Roughly one full-suite run in three, a test that drives a PTY (F004, F013)
  # dies with "Caught deadly signal 'SIGHUP'" instead of finishing. It is never an
  # assertion failure, leaves no stray child processes, and does not reproduce in
  # isolation (F004 passes 10/10 alone, 12/12 under this same watchdog, 8/8 paired
  # with F003) nor in a plugin-free float+jobstart{term=true} teardown loop (0/10).
  # SIGHUP is delivered from outside the process, so it is treated as an
  # environmental event and retried ONCE - loudly, never silently, so a real
  # regression that happened to crash cannot hide behind the retry.
  if [ $status -ne 0 ] && printf '%s' "$output" | grep -q "deadly signal 'SIGHUP'"; then
    echo "RETRY $id (external SIGHUP, not an assertion failure)"
    output=$(run_with_timeout "$TEST_TIMEOUT" nvim --headless -u tests/minimal-init.lua -c "$run_lua" -c "qa!" 2>&1)
    status=$?
    retried="$retried $id"
  fi

  if [ $status -eq 0 ] && printf '%s' "$output" | grep -q "PASS: $id"; then
    echo "PASS $id"
    pass=$((pass + 1))
  else
    echo "FAIL $id (exit=$status)"
    printf '%s\n' "$output" | tail -20
    fail=$((fail + 1))
    failed="$failed $id"
  fi
done

echo ""
echo "Results: $pass passed, $fail failed"
if [ -n "$retried" ]; then
  echo "Retried after external SIGHUP:$retried"
fi
if [ $fail -gt 0 ]; then
  echo "Failed:$failed"
  exit 1
fi
exit 0
