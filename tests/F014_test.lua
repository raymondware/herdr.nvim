-- F014: Sprint 2 QA regressions in the polling engine, the CLI argv and the
-- config defaults. Every section here is a defect that shipped green through
-- F001-F013, so each one states the invariant it defends.
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F014_test.lua" -c "qa!"
--
-- The invariants:
--   1. For ANY config values whatsoever, a poll ends with the in-flight guard
--      cleared, every pending refresh() callback invoked EXACTLY once, and
--      listeners fired EXACTLY once. A stringly-typed max_failures used to throw
--      inside the vim.system callback, between clearing the guard and the
--      fan-out, and silently destroyed every callback in the plugin forever.
--   2. Data attributed to the current config was actually produced by the
--      current config. A response from a superseded cmd/session is discarded,
--      never cached, never published - and never abandons a pending callback.
--   3. config.session reaches the polling subprocess, or a user with a named
--      session watches a server they are not using.
--
-- WHY most of this file fakes cli.agent_list instead of spawning stubs: the
-- defects live in agents.lua's handling of a RESPONSE, and the only thing a real
-- subprocess adds there is seconds of scheduling latency (this machine routinely
-- carries a load average in the hundreds, which made a fixed-window version of
-- this file flaky). agents.lua looks cli.agent_list up on the module table at
-- call time, so the seam is exactly what it calls. Sections 7 and 8, which are
-- about argv and about vim.system's own arguments, use real subprocesses -
-- nothing else can verify those.

local agents = require("herdr.agents")
local cli = require("herdr.cli")
local config = require("herdr.config")
local helpers = dofile(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua"
)

-- Degradation warns on purpose; capture so the only output is the PASS line.
local original_notify = vim.notify
local function silence_notify()
  vim.notify = function() end
end
silence_notify()

-- ===========================================================================
-- The fake CLI.
--
-- Responses are keyed by the REQUEST IDENTITY (cmd + session) that was current
-- when the request was spawned, which is what makes "a response from a
-- superseded config" reproducible: hold a response, change the config, release
-- it, and the data that comes back is provably the old config's.
--
-- cmd values are real fixture names so cli.available() (and therefore
-- agents.start()) behaves normally; no subprocess is ever spawned through here.
-- ===========================================================================
local THREE = {
  { target = "p1", name = "claude-1", state = "working", detail = {} },
  { target = "p2", name = "codex", state = "blocked", detail = {} },
  { target = "p3", name = "reviewer", state = "done", detail = {} },
}
local SOLO = { { target = "p9", name = "solo", state = "working", detail = {} } }

local RESPONSES = {
  ["herdr-stub|"] = THREE,
  ["herdr-stub-v2|"] = SOLO,
  -- Same binary, named session: a different server, so different agents.
  ["herdr-stub|qa3-probe"] = SOLO,
}

local SERVER_DOWN = "herdr server not running (start with `herdr` or `herdr server`)"

local real_agent_list = cli.agent_list
local fake = {
  calls = 0,
  fail = false,
  hold = false,
  held = {}, ---@type fun()[] deliveries the test releases by hand
}

local function identity()
  return ("%s|%s"):format(config.options.cmd or config.defaults.cmd, cli.session() or "")
end

local function install_fake()
  fake.calls, fake.fail, fake.hold, fake.held = 0, false, false, {}
  cli.agent_list = function(cb)
    fake.calls = fake.calls + 1
    local key = identity()
    local failing = fake.fail
    local deliver = function()
      if failing then
        return cb(nil, SERVER_DOWN)
      end
      local list = RESPONSES[key]
      assert(list, "fake CLI has no response for identity " .. key)
      return cb(vim.deepcopy(list))
    end
    if fake.hold then
      fake.held[#fake.held + 1] = deliver
      return
    end
    -- Async like the real one: cli.lua guarantees cb is never called inline.
    vim.schedule(deliver)
  end
end

--- Release every held response, oldest first.
local function release_held()
  local held = fake.held
  fake.held = {}
  for _, deliver in ipairs(held) do
    vim.schedule(deliver)
  end
end

local function restore_cli()
  cli.agent_list = real_agent_list
end

--- Wait for `cond`, with enough headroom for a badly loaded machine.
---@param cond fun(): boolean
---@param what string
local function wait_for(cond, what)
  assert(vim.wait(10000, cond, 10), "timed out waiting for " .. what)
end

install_fake()

-- ===========================================================================
-- 1. Invariant 1 across hostile numeric configs.
--
-- config.setup() validates nothing, so every one of these reaches agents.lua
-- verbatim, and they are read inside the response callback - where a throw does
-- not reach a caller: it is reported by the scheduler and the callback is simply
-- lost, the in-flight guard is never released, and polling wedges silently.
-- ===========================================================================
local HOSTILE = {
  { label = 'max_failures = "3"', opts = { max_failures = "3" } },
  { label = "max_failures = 0", opts = { max_failures = 0 } },
  { label = "max_failures = -5", opts = { max_failures = -5 } },
  { label = "max_failures = {}", opts = { max_failures = {} } },
  { label = "max_failures = false", opts = { max_failures = false } },
  { label = 'poll_interval_ms = "abc"', opts = { poll_interval_ms = "abc" } },
  { label = "poll_interval_ms = 0", opts = { poll_interval_ms = 0 } },
  { label = "poll_interval_ms = -1", opts = { poll_interval_ms = -1 } },
  { label = "poll_interval_ms = inf", opts = { poll_interval_ms = math.huge } },
  { label = "poll_interval_ms = nan", opts = { poll_interval_ms = 0 / 0 } },
  { label = 'cli_timeout_ms = "abc"', opts = { cli_timeout_ms = "abc" } },
  { label = "cli_timeout_ms = 0", opts = { cli_timeout_ms = 0 } },
  { label = "cli_timeout_ms = -9", opts = { cli_timeout_ms = -9 } },
}

for _, case in ipairs(HOSTILE) do
  for _, failing in ipairs({ false, true }) do
    local where = ("%s (%s response)"):format(case.label, failing and "failing" or "successful")
    local opts = vim.deepcopy(case.opts)
    opts.auto_start = false
    config.setup({ cmd = "herdr-stub", agents = opts })
    fake.fail = failing

    local emits, cb_calls = 0, 0
    local unsub = agents.on_update(function()
      emits = emits + 1
    end)
    local calls_before = fake.calls
    agents.refresh(function()
      cb_calls = cb_calls + 1
    end)
    wait_for(function()
      return cb_calls > 0
    end, where .. ": the refresh() callback")
    -- Room for a second, wrong delivery to show up.
    vim.wait(60)
    assert(cb_calls == 1, ("%s: callback fired exactly once, got %d"):format(where, cb_calls))
    assert(emits == 1, ("%s: listeners fired exactly once, got %d"):format(where, emits))
    assert(
      fake.calls == calls_before + 1,
      ("%s: exactly one request was issued, got %d"):format(where, fake.calls - calls_before)
    )
    unsub()

    -- The guard is released, so the next request actually happens.
    local again = 0
    agents.refresh(function()
      again = again + 1
    end)
    wait_for(function()
      return again > 0
    end, where .. ": the in-flight guard to be released")
    assert(not agents.is_polling(), where .. ": refresh() armed no timer")
  end
end
fake.fail = false

-- The same hostile intervals must survive timer:start(), the other place a
-- non-finite number would throw (out of start(), not out of a callback).
for _, case in ipairs(HOSTILE) do
  local opts = vim.deepcopy(case.opts)
  opts.auto_start = false
  config.setup({ cmd = "herdr-stub", agents = opts })
  assert(pcall(agents.start), case.label .. ": start() does not throw")
  assert(agents.is_polling(), case.label .. ": start() armed the timer")
  agents.stop()
end
helpers.assert_no_live_timers("hostile-config start/stop cycles")

-- ===========================================================================
-- 2. A stringly-typed max_failures degrades at the right count instead of
-- throwing. Two witnesses: the request counter and the ordinal of the emit where
-- is_degraded() flipped. Measured before the fix: emits = 0 over 12 ticks,
-- degraded never true, one traceback per tick.
-- ===========================================================================
local errs, degrade_at = 0, nil
local unsub_degrade = agents.on_update(function(_, err)
  if err then
    errs = errs + 1
    if agents.is_degraded() and degrade_at == nil then
      degrade_at = errs
    end
  end
end)

fake.fail = true
fake.calls = 0
config.setup({
  cmd = "herdr-stub",
  agents = { auto_start = false, poll_interval_ms = 100, max_failures = "3" },
})
agents.start()
wait_for(function()
  return not agents.is_polling()
end, 'max_failures = "3" to degrade (it used to throw instead)')
assert(agents.is_degraded(), 'max_failures = "3" sets the degraded flag')
assert(errs == 3, ('a "3" is coerced to 3 failures, got %d'):format(errs))
assert(degrade_at == 3, "degraded on the 3rd failure, got " .. tostring(degrade_at))
assert(fake.calls == 3, "exactly 3 requests were issued, got " .. fake.calls)

-- 0 and negative clamp to 1 (documented in agents.lua: nonsense means give up
-- sooner, never "never give up" - a doomed subprocess loop is the thing
-- degradation exists to stop).
for _, value in ipairs({ 0, -5 }) do
  errs, degrade_at, fake.calls = 0, nil, 0
  config.setup({
    cmd = "herdr-stub",
    agents = { auto_start = false, poll_interval_ms = 100, max_failures = value },
  })
  agents.start()
  wait_for(function()
    return not agents.is_polling()
  end, ("max_failures = %d to degrade"):format(value))
  assert(
    degrade_at == 1,
    ("max_failures = %d clamps to 1, degraded at %s"):format(value, tostring(degrade_at))
  )
  assert(
    fake.calls == 1,
    ("max_failures = %d issued one request, got %d"):format(value, fake.calls)
  )
end
unsub_degrade()
fake.fail = false

-- ===========================================================================
-- 3. poll_interval_ms = 0 must not busy-loop. uv treats a repeat of 0 as
-- one-shot and a 1ms repeat re-issues as fast as the loop turns, so the value is
-- clamped to a 100ms floor: at most ~11 ticks per second, whatever was asked
-- for. Unclamped, the same measurement against a real stub was 26-30/s, and
-- against this instant fake it is far higher still.
-- ===========================================================================
local TICK_CEILING = 15
for _, interval in ipairs({ 0, -1, 1 }) do
  fake.calls = 0
  config.setup({
    cmd = "herdr-stub",
    agents = { auto_start = false, poll_interval_ms = interval },
  })
  agents.start()
  vim.wait(1000)
  agents.stop()
  assert(fake.calls >= 1, ("interval %s: polling really ran"):format(tostring(interval)))
  assert(
    fake.calls <= TICK_CEILING,
    ("interval %s: clamped to the 100ms floor, expected <= %d ticks in 1s, got %d"):format(
      tostring(interval),
      TICK_CEILING,
      fake.calls
    )
  )
end

-- An unparseable interval falls back to the 5000ms DEFAULT, not to the floor:
-- garbage means "the user did not choose", so the plugin uses its own value.
-- One immediate tick and nothing more inside a 1s window.
fake.calls = 0
config.setup({ cmd = "herdr-stub", agents = { auto_start = false, poll_interval_ms = "abc" } })
agents.start()
vim.wait(1000)
agents.stop()
assert(
  fake.calls == 1,
  ('poll_interval_ms = "abc" falls back to the 5000ms default, got %d ticks in 1s'):format(
    fake.calls
  )
)

-- ===========================================================================
-- 4. The fan-out is UNCONDITIONAL: even when the degradation bookkeeping throws,
-- pending callbacks and listeners still fire exactly once. vim.notify is the
-- injection point because warn() is called from inside that bookkeeping, which is
-- exactly where the original defect lived. Before the fix this section measured
-- 0 callbacks and 0 emits.
-- ===========================================================================
fake.fail = true
config.setup({
  cmd = "herdr-stub",
  agents = { auto_start = false, poll_interval_ms = 100, max_failures = 1 },
})
local throw_emits, throw_cbs = 0, 0
local unsub_throw = agents.on_update(function()
  throw_emits = throw_emits + 1
end)
vim.notify = function()
  error("notify blew up inside the degradation warn")
end
agents.start()
agents.refresh(function()
  throw_cbs = throw_cbs + 1
end)
wait_for(function()
  return throw_cbs > 0
end, "a pending callback that a throwing notify used to swallow")
vim.wait(60)
silence_notify()
assert(throw_cbs == 1, "pending callback fired exactly once, got " .. throw_cbs)
assert(throw_emits == 1, "listeners fired exactly once, got " .. throw_emits)
assert(agents.is_degraded(), "the degraded flag was set before the throw")
assert(not agents.is_polling(), "the self-stop happened before the throw")
unsub_throw()

-- The guard is still released, so the module is not wedged.
local after_throw = 0
agents.refresh(function()
  after_throw = after_throw + 1
end)
wait_for(function()
  return after_throw > 0
end, "polling to still work after a throwing notify")
fake.fail = false

-- ===========================================================================
-- 5. Invariant 2: a response from a superseded cmd is discarded, and the pending
-- callback that coalesced onto it is re-issued rather than answered with stale
-- data. Measured before the fix: the callback got n=3 first=claude-1 from the
-- command the user had already reconfigured away from, and the cache stayed wrong
-- indefinitely (nothing re-polls after a timerless refresh).
-- ===========================================================================
local function seed_three()
  config.setup({ cmd = "herdr-stub", agents = { auto_start = false, poll_interval_ms = 100 } })
  local seeded = false
  agents.refresh(function(list)
    seeded = list ~= nil and #list == 3
  end)
  wait_for(function()
    return seeded
  end, "the cache to be seeded with 3 agents")
end
seed_three()

fake.hold = true
agents.refresh() -- request out, spawned under cmd = herdr-stub
wait_for(function()
  return #fake.held == 1
end, "the held request to be issued")
-- The user reconfigures while that request is still out.
config.setup({ cmd = "herdr-stub-v2", agents = { auto_start = false, poll_interval_ms = 100 } })

local stale_emits = 0
local unsub_stale = agents.on_update(function(list, err)
  if err == nil and #list ~= 1 then
    stale_emits = stale_emits + 1
  end
end)
local swapped_list, swapped_err, swapped_calls = nil, nil, 0
agents.refresh(function(list, err)
  swapped_calls = swapped_calls + 1
  swapped_list, swapped_err = list, err
end)
fake.hold = false
release_held() -- the superseded response lands now
wait_for(function()
  return swapped_calls > 0
end, "the coalesced callback to be honored across a cmd swap")
vim.wait(60)
assert(swapped_calls == 1, "the coalesced callback fired exactly once, got " .. swapped_calls)
assert(swapped_err == nil, "the re-issued request succeeded: " .. tostring(swapped_err))
assert(
  type(swapped_list) == "table" and #swapped_list == 1 and swapped_list[1].name == "solo",
  "the callback got the NEW config's data, not the superseded command's: "
    .. vim.inspect(vim.tbl_map(function(agent)
      return agent.name
    end, swapped_list or {}))
)
assert(agents.counts().total == 1, "the superseded response never reached the cache")
assert(stale_emits == 0, "no listener was ever handed the superseded command's agents")
unsub_stale()

-- ===========================================================================
-- 6. The user-facing path: :HerdrPoll stop -> reconfigure -> :HerdrPoll start.
-- The freshly armed timer's first tick used to be swallowed by the still
-- in-flight old request, so for ~1.8s the plugin displayed the previous
-- configuration's agents as current, with last_error() == nil and no degraded
-- flag - indistinguishable from correct data.
-- ===========================================================================
seed_three()
fake.hold = true
agents.start() -- immediate tick, request held under cmd = herdr-stub
wait_for(function()
  return #fake.held == 1
end, "the restart-path request to be issued")
agents.stop()
config.setup({ cmd = "herdr-stub-v2", agents = { auto_start = false, poll_interval_ms = 100 } })

local restart_violations = 0
local unsub_restart = agents.on_update(function(list, err)
  if err == nil and #list ~= 1 then
    restart_violations = restart_violations + 1
  end
end)
agents.start()
fake.hold = false
release_held()
wait_for(function()
  return agents.counts().total == 1
end, "the restarted poll to deliver the new config's data")
assert(
  restart_violations == 0,
  ("the old config's agents were published %d time(s) after the restart"):format(
    restart_violations
  )
)
assert(agents.last_error() == nil, "no error was invented while discarding the stale response")
unsub_restart()
agents.stop()

-- ===========================================================================
-- 7. Invariant 3, part one: the session is part of the request identity, so a
-- response produced before the session changed is discarded exactly like a cmd
-- change. Same binary both times - only the session differs.
-- ===========================================================================
seed_three()
fake.hold = true
agents.refresh()
wait_for(function()
  return #fake.held == 1
end, "the pre-session-change request to be issued")
config.setup({
  cmd = "herdr-stub",
  session = "qa3-probe",
  agents = { auto_start = false, poll_interval_ms = 100 },
})
local session_list, session_calls = nil, 0
agents.refresh(function(list)
  session_calls = session_calls + 1
  session_list = list
end)
fake.hold = false
release_held()
wait_for(function()
  return session_calls > 0
end, "the callback to survive a session change mid-flight")
vim.wait(60)
assert(session_calls == 1, "one callback after a session change, got " .. session_calls)
assert(
  type(session_list) == "table" and #session_list == 1 and session_list[1].name == "solo",
  "the data came from the NEW session, not from the pre-change request"
)
assert(agents.counts().total == 1, "the pre-change response never reached the cache")

restore_cli()

-- ===========================================================================
-- 8. Invariant 3, part two: config.session actually reaches the subprocess.
-- This needs a real spawn - it is about argv, which no seam can stand in for.
--
-- `--session <name>` is a global flag herdr 0.7.5 accepts before OR after the
-- subcommand (both verified live; see docs/herdr-cli-facts.md). The plugin
-- appends it so positional subcommand arguments keep their argv indices.
-- ===========================================================================
local scratch = vim.fn.tempname()
assert(vim.fn.mkdir(scratch, "p") == 1, "scratch dir for the argv-recording stub")
vim.env.PATH = scratch .. ":" .. vim.env.PATH

local argv_log = scratch .. "/argv.log"
local GET_SOLO =
  [[{"id":"cli:agent:get","result":{"agent":{"terminal_id":"t9","agent_status":"working","workspace_id":"w1","tab_id":"tb1","pane_id":"p9","focused":true,"revision":1,"agent":"claude","name":"solo","title":null},"type":"agent_get"}}]]
local LIST_SOLO =
  [[{"id":"cli:agent:list","result":{"agents":[{"terminal_id":"t9","agent_status":"working","workspace_id":"w1","tab_id":"tb1","pane_id":"p9","focused":true,"revision":1,"agent":"claude","name":"solo","title":null}],"type":"agent_list"}}]]

local stub = scratch .. "/f014-argv"
assert(
  vim.fn.writefile({
    "#!/bin/sh",
    ('printf "%%s\\n" "$*" >> "%s"'):format(argv_log),
    ('if [ "$1" = "agent" ] && [ "$2" = "get" ]; then printf "%%s\\n" \'%s\'; exit 0; fi'):format(
      GET_SOLO
    ),
    ("printf '%%s\\n' '%s'"):format(LIST_SOLO),
    "exit 0",
  }, stub) == 0,
  "wrote the argv-recording stub"
)
vim.fn.setfperm(stub, "rwxr-xr-x")
assert(vim.fn.executable("f014-argv") == 1, "the argv stub is executable on $PATH")

---@return string[]
local function argv_lines()
  if vim.fn.filereadable(argv_log) == 0 then
    return {}
  end
  return vim.fn.readfile(argv_log)
end

config.setup({ cmd = "f014-argv", agents = { auto_start = false, poll_interval_ms = 100 } })
assert(cli.session() == nil, "session = nil resolves to no session")
vim.fn.delete(argv_log)
local plain_list = nil
agents.refresh(function(list)
  plain_list = list
end)
wait_for(function()
  return plain_list ~= nil
end, "the unsessioned poll")
assert(#argv_lines() == 1, "one invocation recorded, got " .. #argv_lines())
assert(
  argv_lines()[1] == "agent list",
  "no session means no flag: " .. ("%q"):format(argv_lines()[1])
)

config.setup({
  cmd = "f014-argv",
  session = "qa3-probe",
  agents = { auto_start = false, poll_interval_ms = 100 },
})
assert(cli.session() == "qa3-probe", "cli.session() reports the configured session")
vim.fn.delete(argv_log)
local sessioned_list = nil
agents.refresh(function(list)
  sessioned_list = list
end)
wait_for(function()
  return sessioned_list ~= nil
end, "the sessioned poll")
assert(
  argv_lines()[1] == "agent list --session qa3-probe",
  "the poll targets the configured session: " .. ("%q"):format(argv_lines()[1])
)
assert(#sessioned_list == 1, "the sessioned poll still parses normally")

-- agent get gets the flag too, after its positional target.
vim.fn.delete(argv_log)
local got_agent = nil
cli.agent_get("p9", function(agent)
  got_agent = agent
end)
wait_for(function()
  return got_agent ~= nil
end, "agent get")
assert(
  argv_lines()[1] == "agent get p9 --session qa3-probe",
  "agent get targets the session with the positional target intact: "
    .. ("%q"):format(argv_lines()[1])
)
assert(got_agent.name == "solo", "agent get still parses normally")

-- A blank session is not a session.
for _, blank in ipairs({ "", "   " }) do
  config.setup({ cmd = "f014-argv", session = blank, agents = { auto_start = false } })
  assert(cli.session() == nil, ("session = %q is treated as unset"):format(blank))
end

-- ===========================================================================
-- 9. A non-numeric cli_timeout_ms must never reach vim.system. It used to, and
-- the throw landed AFTER the child was spawned, so the callback ran twice: once
-- from the failed-spawn path and once when the process actually exited. That is
-- the same cb-exactly-once contract cli.lua documents.
-- ===========================================================================
for _, timeout in ipairs({ "abc", 0, -9, math.huge }) do
  config.setup({
    cmd = "f014-argv",
    agents = { auto_start = false, poll_interval_ms = 100, cli_timeout_ms = timeout },
  })
  local calls, seen_err = 0, nil
  agents.refresh(function(_, err)
    calls = calls + 1
    seen_err = err
  end)
  wait_for(function()
    return calls > 0
  end, ("a poll with cli_timeout_ms = %s"):format(tostring(timeout)))
  vim.wait(120)
  assert(
    calls == 1,
    ("cli_timeout_ms = %s delivered the callback exactly once, got %d"):format(
      tostring(timeout),
      calls
    )
  )
  assert(
    seen_err == nil,
    ("cli_timeout_ms = %s fell back to a usable timeout: %s"):format(
      tostring(timeout),
      tostring(seen_err)
    )
  )
end

-- ===========================================================================
-- 10. The two keys that used to be documented but absent from config.defaults.
-- The README and vimdoc default blocks are machine-diffed against
-- config.defaults, so a key that only exists as a module-local fallback is a
-- documentation lie.
-- ===========================================================================
config.setup({})
assert(type(config.defaults.agents_window) == "table", "agents_window is a real default")
assert(config.defaults.agents_window.width == 72, "agents_window.width default")
assert(config.defaults.agents_window.height == 0.5, "agents_window.height default")
assert(config.defaults.agents_window.border == "rounded", "agents_window.border default")
assert(config.defaults.agents_window.title == " herdr agents ", "agents_window.title default")
assert(config.defaults.lualine.show_when_idle == false, "lualine.show_when_idle default")
assert(
  config.defaults.lualine.format == "{working} {blocked} {done} {idle}",
  "the default format can express an idle-only fleet: " .. config.defaults.lualine.format
)
-- A partial user table still gets the sibling defaults.
config.setup({ agents_window = { width = 40 } })
assert(config.options.agents_window.width == 40, "agents_window.width override")
assert(config.options.agents_window.height == 0.5, "sibling agents_window.height kept")
assert(config.options.agents_window.title == " herdr agents ", "sibling agents_window.title kept")

-- ===========================================================================
-- 11. Teardown: no timer, no listeners, no live uv handle.
-- ===========================================================================
agents.cleanup()
assert(not agents.is_polling(), "no polling left at test end")
helpers.assert_no_live_timers("after cleanup() at test end")
vim.fn.delete(scratch, "rf")

vim.notify = original_notify
print("PASS: F014 numeric config coercion, unconditional fan-out, superseded-response discard, session routing")
