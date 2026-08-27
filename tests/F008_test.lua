-- F008: dedicated verification of the failure degradation contract in
-- lua/herdr/agents.lua (self-stop after exactly max_failures CONSECUTIVE
-- failures, exactly one WARN notify, recovery, and the refresh() carve-out).
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F008_test.lua" -c "qa!"
--
-- WHY generated stubs instead of tests/fixtures/herdr-stub-fail: this feature is
-- about how MANY times the binary runs, and the checked-in fail fixture keeps no
-- invocation count. Two throwaway scripts are written under vim.fn.tempname()
-- so the count is real subprocess evidence and the shared fixtures stay
-- untouched (F007/F009 assert against them).
--
-- Timer hygiene is asserted by a HANDLE CENSUS (helpers.timer_census), not by
-- the exit: nvim 0.12 exits promptly even with 30 orphaned, still-firing uv
-- timers, so "it exited, therefore nothing leaked" is not an assertion at all.

local agents = require("herdr.agents")
local config = require("herdr.config")
local helpers = dofile(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua"
)

-- Degradation warns on purpose; capture instead of printing so the only output
-- is the PASS line, and so WARN-level notifications can be counted exactly.
local original_notify = vim.notify
local notifications = {}
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end

--- WARN-or-higher notifications recorded after `mark` (a previous #notifications).
---@param mark integer
---@return table[]
local function warns_since(mark)
  local out = {}
  for i = mark + 1, #notifications do
    local entry = notifications[i]
    if (entry.level or vim.log.levels.INFO) >= vim.log.levels.WARN then
      out[#out + 1] = entry
    end
  end
  return out
end

local SERVER_DOWN_STDERR =
  [[echo 'Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }' >&2]]

-- Same envelope shape as tests/fixtures/herdr-stub (3 agents).
local LIST_ENVELOPE =
  [[{"id":"cli:agent:list","result":{"agents":[{"terminal_id":"t1","agent_status":"working","workspace_id":"w1","tab_id":"tb1","pane_id":"p1","focused":true,"revision":3,"agent":"claude","name":"claude-1","title":null},{"terminal_id":"t2","agent_status":"blocked","workspace_id":"w1","tab_id":"tb1","pane_id":"p2","focused":false,"revision":5,"agent":"codex","name":null,"display_agent":"codex"},{"terminal_id":"t3","agent_status":"done","workspace_id":"w1","tab_id":"tb2","pane_id":"p3","focused":false,"revision":2,"agent":"claude","name":"reviewer"}],"type":"agent_list"}}]]

local scratch = vim.fn.tempname()
assert(vim.fn.mkdir(scratch, "p") == 1, "scratch dir for generated stubs")
-- Prepended, so the generated stubs win over anything else named the same.
vim.env.PATH = scratch .. ":" .. vim.env.PATH

---@param name string
---@param body string[] shell lines after the shebang
---@return string absolute path
local function write_stub(name, body)
  local path = scratch .. "/" .. name
  local lines = { "#!/bin/sh" }
  vim.list_extend(lines, body)
  assert(vim.fn.writefile(lines, path) == 0, "wrote stub " .. name)
  vim.fn.setfperm(path, "rwxr-xr-x")
  assert(vim.fn.executable(name) == 1, name .. " is on $PATH and executable")
  return path
end

---@param path string counter file written by a generated stub
---@return integer
local function count_at(path)
  if vim.fn.filereadable(path) == 0 then
    return 0
  end
  return tonumber(vim.fn.readfile(path)[1] or "0") or 0
end

-- Bump the counter file, then report the server as down.
local fail_count_file = scratch .. "/fail.count"
write_stub("herdr-stub-fail-counted", {
  "n=0",
  ('if [ -f "%s" ]; then n=$(cat "%s"); fi'):format(fail_count_file, fail_count_file),
  ('echo $((n + 1)) > "%s"'):format(fail_count_file),
  SERVER_DOWN_STDERR,
  "exit 1",
})

-- Odd invocations fail, even invocations succeed: alternating, never consecutive.
local flap_count_file = scratch .. "/flap.count"
write_stub("herdr-stub-flappy", {
  "n=0",
  ('if [ -f "%s" ]; then n=$(cat "%s"); fi'):format(flap_count_file, flap_count_file),
  "n=$((n + 1))",
  ('echo "$n" > "%s"'):format(flap_count_file),
  "if [ $((n % 2)) -eq 1 ]; then",
  "  " .. SERVER_DOWN_STDERR,
  "  exit 1",
  "fi",
  ("printf '%%s\\n' '%s'"):format(LIST_ENVELOPE),
  "exit 0",
})

-- 1. Baseline: nothing is degraded before a single poll has run, and no uv
-- timer exists yet (so every later census has a meaningful zero to return to).
assert(helpers.timer_census() == 0, "no uv timer exists before the plugin arms one")
assert(not agents.is_polling(), "no timer armed at script start")
assert(not agents.is_degraded(), "not degraded before any poll")
assert(agents.last_error() == nil, "last_error() is nil before any poll")

-- 2. max_failures = 3 self-stops after EXACTLY 3 failures. Two independent
-- witnesses: the stub's own invocation counter (real subprocess spawns) and the
-- ordinal of the on_update emit where is_degraded() first flipped.
local errs, oks, degrade_at_err = 0, 0, nil
local unsub = agents.on_update(function(list, err)
  if err then
    errs = errs + 1
    if agents.is_degraded() and degrade_at_err == nil then
      degrade_at_err = errs
    end
  else
    oks = oks + 1
    assert(type(list) == "table", "successful emit carries the agent list")
  end
end)

local mark = #notifications
config.setup({
  cmd = "herdr-stub-fail-counted",
  agents = { poll_interval_ms = 50, max_failures = 3 },
})
agents.start()
assert(agents.is_polling(), "start() armed the timer against the failing stub")

assert(vim.wait(8000, function()
  return not agents.is_polling()
end, 20), "3 consecutive failures self-stop polling")

-- The self-stop must CLOSE the handle, not merely stop it: a stopped-but-open
-- timer is invisible to is_polling() and to the exit, and visible only here.
helpers.assert_no_live_timers("degradation self-stop")

assert(errs == 3, "exactly 3 failure emits, got " .. errs)
assert(oks == 0, "no successful emit against the failing stub")
assert(degrade_at_err == 3, "degraded on the 3rd failure, not the 2nd: got " .. tostring(degrade_at_err))
assert(count_at(fail_count_file) == 3, "the stub ran exactly 3 times, got " .. count_at(fail_count_file))
assert(agents.is_degraded(), "is_degraded() true after the failure budget is gone")

local last = agents.last_error()
assert(type(last) == "string", "last_error() is a string while degraded")
assert(last:lower():match("server"), "last_error() names the server: " .. last)

-- No 4th spawn: a stopped timer must not keep ticking. 6 intervals of headroom.
vim.wait(400)
assert(count_at(fail_count_file) == 3, "no further spawns after the self-stop, got " .. count_at(fail_count_file))
assert(errs == 3, "no further failure emits after the self-stop, got " .. errs)

local degrade_warns = warns_since(mark)
assert(#degrade_warns == 1, "exactly ONE WARN notify on degradation, got " .. #degrade_warns)
assert(degrade_warns[1].level == vim.log.levels.WARN, "the degradation notify is WARN level")
assert(degrade_warns[1].msg:match("^herdr:"), "the warn is prefixed with herdr: " .. degrade_warns[1].msg)
assert(degrade_warns[1].msg:match("3 consecutive failures"), "the warn reports the failure count")

-- 3. Recovery. start() clears the degraded flag and the failure counter up
-- front; last_error() is deliberately NOT cleared by start() (it stays as
-- history until a poll actually succeeds), so both halves are asserted.
mark = #notifications
config.setup({ cmd = "herdr-stub", agents = { poll_interval_ms = 100 } })
agents.start()
assert(agents.is_polling(), "start() re-arms after degradation")
assert(not agents.is_degraded(), "start() clears the degraded flag immediately")
assert(agents.last_error() == last, "start() keeps last_error() as history until a poll lands")

assert(vim.wait(5000, function()
  return agents.counts().total == 3
end, 20), "counts repopulate after recovery")
assert(agents.last_error() == nil, "a successful poll clears last_error()")
assert(oks > 0, "the recovered poll emitted a success")
assert(not agents.is_degraded(), "still healthy while polling succeeds")
assert(#warns_since(mark) == 0, "recovery is silent")

-- 4. Non-consecutive failures must NEVER degrade. The flappy stub alternates
-- fail/success, so with max_failures = 2 the only way to survive is for a
-- success to reset the counter.
agents.stop()
mark = #notifications
local errs_before, oks_before = errs, oks
config.setup({
  cmd = "herdr-stub-flappy",
  agents = { poll_interval_ms = 50, max_failures = 2 },
})
agents.start()

assert(vim.wait(8000, function()
  return (errs - errs_before) >= 4 and (oks - oks_before) >= 4
end, 20), ("flappy stub produced interleaved results: %d fail / %d ok"):format(
  errs - errs_before,
  oks - oks_before
))
assert(agents.is_polling(), "alternating failures never stop polling")
assert(not agents.is_degraded(), "alternating failures never degrade (max_failures = 2)")
assert(#warns_since(mark) == 0, "no WARN notify while failures stay non-consecutive")
-- Every emit came from one spawn, so the counter corroborates the interleaving.
assert(
  count_at(flap_count_file) == (errs - errs_before) + (oks - oks_before),
  "one spawn per emit against the flappy stub"
)
agents.stop()

-- 5. Repeated degradation: the "notified once" latch is the armed timer itself,
-- so re-arming with start() must let a SECOND degradation warn again.
mark = #notifications
local errs_at_second = errs
config.setup({
  cmd = "herdr-stub-fail-counted",
  agents = { poll_interval_ms = 50, max_failures = 3 },
})
local spawns_before = count_at(fail_count_file)
agents.start()
assert(not agents.is_degraded(), "start() cleared the earlier degradation")

assert(vim.wait(8000, function()
  return not agents.is_polling()
end, 20), "the second degradation also self-stops polling")
assert(agents.is_degraded(), "degraded again")
assert(errs - errs_at_second == 3, "the failure counter restarted from zero, got " .. (errs - errs_at_second))
assert(
  count_at(fail_count_file) - spawns_before == 3,
  "exactly 3 more spawns for the second degradation"
)

local second_warns = warns_since(mark)
assert(#second_warns == 1, "the second degradation also emits exactly ONE WARN, got " .. #second_warns)
assert(second_warns[1].msg:match("3 consecutive failures"), "the second warn reports the failure count")

-- 6. refresh() with no timer armed must NOT degrade (documented F007 design:
-- degradation is a property of the poll loop), but must still set last_error().
-- Clear the degraded state with a real successful one-shot first.
config.setup({ cmd = "herdr-stub", agents = { poll_interval_ms = 100 } })
local cleared = false
agents.refresh(function(list, err)
  cleared = list ~= nil and err == nil
end)
assert(vim.wait(5000, function()
  return cleared
end, 20), "a one-shot refresh succeeds against herdr-stub")
assert(not agents.is_degraded(), "a successful refresh clears degraded without a timer")
assert(not agents.is_polling(), "refresh() arms no timer")
assert(agents.last_error() == nil, "a successful refresh clears last_error()")

mark = #notifications
config.setup({
  cmd = "herdr-stub-fail-counted",
  agents = { poll_interval_ms = 50, max_failures = 3 },
})
-- Sequential (not batched): refresh() coalesces onto an in-flight request, so
-- five overlapping calls would be a single failure, not five.
for i = 1, 5 do
  local landed = false
  local seen_err = nil
  agents.refresh(function(_, err)
    seen_err = err
    landed = true
  end)
  assert(vim.wait(5000, function()
    return landed
  end, 20), "refresh " .. i .. " landed")
  assert(type(seen_err) == "string", "refresh " .. i .. " reported an error")
  assert(not agents.is_polling(), "refresh " .. i .. " armed no timer")
  assert(not agents.is_degraded(), "refresh failure " .. i .. " must not degrade")
end
local refresh_err = agents.last_error()
assert(type(refresh_err) == "string", "refresh failures still set last_error()")
assert(refresh_err:lower():match("server"), "last_error() names the server: " .. refresh_err)
assert(#warns_since(mark) == 0, "timerless refresh failures stay silent")
-- The cache is deliberately kept on failure so consumers can show stale data.
assert(agents.counts().total == 3, "the last good agent list survives failures")

-- 7. Teardown: no timer, no listeners, and no surviving uv handle. The census
-- is the assertion; the exit would happen either way.
unsub()
agents.cleanup()
assert(not agents.is_polling(), "no polling left at test end")
helpers.assert_no_live_timers("after cleanup() at test end")
vim.fn.delete(scratch, "rf")

vim.notify = original_notify
print("PASS: F008 failure degradation self-stops after exactly max_failures, warns once, and recovers")
