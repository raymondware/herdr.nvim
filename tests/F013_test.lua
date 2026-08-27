-- F013: regression tests for the Sprint 1 QA findings (qa-reports/F003.md,
-- F004.md, F005.md, F006.md). Every block below FAILED before the refine pass;
-- they exist so the same defects cannot come back.
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F013_test.lua" -c "qa!"
--
-- Deliberately uses real subprocesses (throwaway stubs under vim.fn.tempname())
-- rather than string fixtures for the callback-invariant block: the original
-- defect only manifested through vim.system's scheduled callback, where a
-- throw is swallowed by the scheduler instead of reaching the caller.

local cli = require("herdr.cli")
local config = require("herdr.config")

-- Degradation and guard paths notify on purpose; capture so the only output is
-- the PASS line.
local original_notify = vim.notify
local notifications = {}
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end

--- Write an executable throwaway stub.
---@param lines string[] shell script lines
---@return string path
local function stub(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  vim.fn.setfperm(path, "rwx------")
  return path
end

--------------------------------------------------------------------------------
-- 1. THE INVARIANT: for ANY subprocess output whatsoever, cb fires exactly once.
--    Before: `{"agents":[1,2,3]}` threw inside the vim.system callback and cb
--    was never called at all, which wedges agents.lua's in_flight guard forever.
--------------------------------------------------------------------------------

---@param cmd_path string
---@return boolean pcall_ok, table[] calls
local function agent_list_calls(cmd_path)
  config.setup({ cmd = cmd_path, agents = { auto_start = false, cli_timeout_ms = 2000 } })
  local calls = {}
  local ok = pcall(cli.agent_list, function(list, err)
    calls[#calls + 1] = { list = list, err = err }
  end)
  vim.wait(4000, function()
    return #calls > 0
  end)
  -- Give a stray second callback a chance to land before counting.
  vim.wait(120)
  return ok, calls
end

local INVARIANT_CASES = {
  {
    label = "non-object array entries",
    lines = {
      "#!/bin/sh",
      [[printf '%s\n' '{"id":"x","result":{"agents":[1,2,3],"type":"agent_list"}}']],
    },
    expect_list = true,
  },
  {
    label = "bare null",
    lines = { "#!/bin/sh", "printf 'null\\n'" },
    expect_list = false,
  },
  {
    label = "garbage",
    lines = { "#!/bin/sh", "printf 'not json at all <<<>>>\\n'" },
    expect_list = false,
  },
  {
    label = "no output",
    lines = { "#!/bin/sh", "exit 0" },
    expect_list = false,
  },
  {
    label = "true entry",
    lines = {
      "#!/bin/sh",
      [[printf '%s\n' '{"id":"x","result":{"agents":[true],"type":"agent_list"}}']],
    },
    expect_list = true,
  },
  {
    -- An object-shaped `agents` used to yield a silent empty-but-successful
    -- list ("no agents") rather than an envelope error.
    label = "agents given as an object",
    lines = {
      "#!/bin/sh",
      [[printf '%s\n' '{"id":"x","result":{"agents":{"a":1},"type":"agent_list"}}']],
    },
    expect_list = false,
  },
}

for _, case in ipairs(INVARIANT_CASES) do
  local ok, calls = agent_list_calls(stub(case.lines))
  assert(ok, "agent_list must not throw for " .. case.label)
  assert(#calls == 1, ("cb fires exactly once for %s (got %d)"):format(case.label, #calls))
  local call = calls[1]
  if case.expect_list then
    assert(type(call.list) == "table", "list delivered for " .. case.label)
    assert(call.err == nil, "no error for " .. case.label)
  else
    assert(call.list == nil, "no list for " .. case.label)
    assert(type(call.err) == "string" and call.err ~= "", "error string for " .. case.label)
  end
end

-- Non-object entries are skipped, valid ones survive the same envelope. (An
-- object entry is trusted even when sparse - it can still carry a pane_id.)
local mixed = cli.parse_agent_list(
  '{"result":{"agents":[1,"x",{"pane_id":"p9","agent_status":"working"},false],'
    .. '"type":"agent_list"}}'
)
assert(type(mixed) == "table", "mixed envelope parses")
assert(#mixed == 1, "only the one real AgentInfo survives (got " .. #mixed .. ")")
assert(mixed[1].target == "p9", "surviving agent keeps its pane_id target")

-- normalize_agent is safe as a public API for any input.
for _, bad in ipairs({ 1, true, "str" }) do
  assert(cli.normalize_agent(bad) == nil, "normalize_agent rejects " .. type(bad))
end
assert(cli.normalize_agent(nil) == nil, "normalize_agent rejects nil")

-- Same hardening on agent_get.
local get_stub = stub({
  "#!/bin/sh",
  [[printf '%s\n' '{"id":"x","result":{"agent":[1,2],"type":"agent_get"}}']],
})
config.setup({ cmd = get_stub, agents = { auto_start = false } })
local get_calls = {}
assert(pcall(cli.agent_get, "p1", function(agent, err)
  get_calls[#get_calls + 1] = { agent = agent, err = err }
end), "agent_get must not throw on a non-object result.agent")
vim.wait(4000, function()
  return #get_calls > 0
end)
vim.wait(120)
assert(#get_calls == 1, "agent_get cb fires exactly once (got " .. #get_calls .. ")")
assert(get_calls[1].agent == nil and type(get_calls[1].err) == "string", "agent_get reports the error")

print("PASS: F013.1 callback invariant - cb fires exactly once for any output")

--------------------------------------------------------------------------------
-- 2. herdr's JSON error envelope must never be shown raw (qa-reports/F003 MAJOR 2).
--    Real shape, verified live against herdr 0.7.5; see docs/herdr-cli-facts.md.
--------------------------------------------------------------------------------

local ENVELOPE =
  '{"error":{"code":"agent_not_found","message":"agent target p-zzz not found"},"id":"cli:agent:get"}'

local pure = cli.normalize_error({ code = 1, stderr = ENVELOPE })
assert(pure == "herdr: agent target p-zzz not found", "normalize_error extracts .error.message, got: " .. pure)
assert(not pure:find("{", 1, true), "no raw JSON leaks into the message")

-- Envelope on stdout is handled too (herdr uses stderr, but be defensive).
assert(
  cli.normalize_error({ code = 1, stdout = ENVELOPE }) == "herdr: agent target p-zzz not found",
  "envelope on stdout is also extracted"
)

-- The server-down mapping still wins over generic handling.
assert(
  cli.normalize_error({
    code = 1,
    stderr = 'Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }',
  }) == "herdr server not running (start with `herdr` or `herdr server`)",
  "server-down signature keeps its actionable message"
)

-- Unparseable / partial envelopes fall back to the raw text rather than throwing.
assert(
  cli.normalize_error({ code = 1, stderr = '{"error":{"code":"x"}}' }):find("exited with code 1"),
  "an envelope with no message falls back to the raw text"
)
assert(cli.normalize_error({ code = 2, stderr = "plain boom" }) == "herdr exited with code 2: plain boom")
assert(cli.normalize_error({ code = 2 }) == "herdr exited with code 2", "no dangling colon without stderr")

-- normalize_error is the error path: it must never throw, for any input.
for _, bad in ipairs({ { code = 1, stderr = 3 }, { stderr = {} }, {}, 7, "str" }) do
  local ok, msg = pcall(cli.normalize_error, bad)
  assert(ok, "normalize_error must not throw for " .. vim.inspect(bad))
  assert(type(msg) == "string", "normalize_error always returns a string")
end
assert(select(2, pcall(cli.normalize_error, nil)) ~= nil, "normalize_error(nil) returns a string")
assert(pcall(cli.normalize_error, nil), "normalize_error(nil) must not throw")

-- End to end through a real subprocess emitting the envelope on stderr.
local envelope_stub = stub({
  "#!/bin/sh",
  ("printf '%%s\\n' '%s' >&2"):format(ENVELOPE),
  "exit 1",
})
config.setup({ cmd = envelope_stub, agents = { auto_start = false } })
local env_calls = {}
cli.agent_get("p-zzz", function(agent, err)
  env_calls[#env_calls + 1] = { agent = agent, err = err }
end)
vim.wait(4000, function()
  return #env_calls > 0
end)
assert(#env_calls == 1, "envelope stub delivers exactly one callback")
assert(
  env_calls[1].err == "herdr: agent target p-zzz not found",
  "subprocess envelope surfaces the human message, got: " .. tostring(env_calls[1].err)
)

print("PASS: F013.2 error envelope message extraction")

--------------------------------------------------------------------------------
-- 3. A timed-out call says so instead of "exited with code 124:" (F003 MINOR 3).
--------------------------------------------------------------------------------

local hang_stub = stub({ "#!/bin/sh", "exec sleep 30" })
config.setup({ cmd = hang_stub, agents = { auto_start = false, cli_timeout_ms = 400 } })
local timeout_calls = {}
cli.agent_list(function(list, err)
  timeout_calls[#timeout_calls + 1] = { list = list, err = err }
end)
vim.wait(5000, function()
  return #timeout_calls > 0
end)
assert(#timeout_calls == 1, "a timeout still delivers exactly one callback")
assert(
  timeout_calls[1].err == "herdr command timed out after 400ms",
  "timeout is reported as a timeout, got: " .. tostring(timeout_calls[1].err)
)

-- A genuine exit code 124 with no signal is NOT a timeout.
assert(
  cli.normalize_error({ code = 124, signal = 0, stderr = "real failure" }, 400)
    == "herdr exited with code 124: real failure",
  "exit 124 without a signal is not misreported as a timeout"
)

print("PASS: F013.3 timeout is reported as a timeout")

--------------------------------------------------------------------------------
-- 4. hl.setup() runs from init.setup() (F005 MAJOR 3). architecture.json puts it
--    right after config.setup(); all five groups were undefined before the fix.
--------------------------------------------------------------------------------

local HL_LINKS = {
  HerdrAgentWorking = "DiagnosticWarn",
  HerdrAgentBlocked = "DiagnosticError",
  HerdrAgentDone = "DiagnosticOk",
  HerdrAgentIdle = "Comment",
  HerdrHeader = "Title",
}

for name in pairs(HL_LINKS) do
  assert(
    vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = name })),
    name .. " must be undefined before setup() (otherwise this test proves nothing)"
  )
end

local herdr = require("herdr")
-- herdr-stub instead of the default "herdr" so auto_start cannot talk to the
-- user's real server; the highlight wiring is independent of cmd.
herdr.setup({ cmd = "herdr-stub" })

for name, link in pairs(HL_LINKS) do
  local group = vim.api.nvim_get_hl(0, { name = name })
  assert(not vim.tbl_isempty(group), name .. " defined after setup()")
  assert(group.link == link, ("%s links to %s (got %s)"):format(name, link, tostring(group.link)))
end
assert(#vim.api.nvim_get_autocmds({ group = "HerdrHl", event = "ColorScheme" }) == 1,
  "hl.setup() installs exactly one ColorScheme re-apply autocmd")

require("herdr.agents").stop()
print("PASS: F013.4 highlight groups defined by setup()")

--------------------------------------------------------------------------------
-- 5. setup() takes back the keymaps it created (F005 MAJOR 2), and never touches
--    a mapping it did not create.
--------------------------------------------------------------------------------

---@return boolean
local function mapped(lhs)
  local map = vim.fn.maparg(lhs, "n", false, true)
  return type(map) == "table" and not vim.tbl_isempty(map)
end

---@return string|nil
local function map_desc(lhs)
  local map = vim.fn.maparg(lhs, "n", false, true)
  if type(map) ~= "table" then
    return nil
  end
  return map.desc
end

local BASE = { cmd = "herdr-stub", agents = { auto_start = false } }

---@param keymaps table|nil
local function setup_with(keymaps)
  herdr.setup(vim.tbl_extend("force", vim.deepcopy(BASE), { keymaps = keymaps }))
end

-- (a) default setup() then toggle = false -> <C-r> is released
setup_with(nil)
assert(mapped("<C-r>"), "default setup() maps <C-r>")
setup_with({ toggle = false })
assert(not mapped("<C-r>"), "toggle=false after a default setup() unmaps <C-r>")

-- (b) retargeting toggle moves the mapping instead of duplicating it
setup_with(nil)
assert(mapped("<C-r>"), "<C-r> mapped again")
setup_with({ toggle = "<C-g>" })
assert(not mapped("<C-r>"), "retargeting toggle unmaps the old lhs")
assert(mapped("<C-g>"), "retargeting toggle maps the new lhs")

-- (c) unsetting keymaps.agents releases its lhs
setup_with({ toggle = false, agents = "<leader>qq" })
assert(mapped("<leader>qq"), "keymaps.agents maps its lhs")
setup_with({ toggle = false })
assert(not mapped("<leader>qq"), "unsetting keymaps.agents unmaps its lhs")

-- (d) a user remap on our lhs is never clobbered: the desc fingerprint has to
--     still be ours before we delete anything.
setup_with({ toggle = "<C-g>" })
assert(map_desc("<C-g>") == "herdr: toggle terminal", "our mapping is fingerprinted by desc")
vim.keymap.set("n", "<C-g>", function() end, { desc = "user: mine now" })
setup_with({ toggle = false })
assert(mapped("<C-g>"), "a user remap on our old lhs survives")
assert(map_desc("<C-g>") == "user: mine now", "the surviving mapping is the user's")
vim.keymap.del("n", "<C-g>")

print("PASS: F013.5 keymap lifecycle - created maps are released, user maps are not")

--------------------------------------------------------------------------------
-- 6. health gates on 0.11, not 0.10 (F006 MAJOR). jobstart{term=true} and the
--    4-arg vim.validate() are both 0.11 features (news-0.11.txt:370 and :292).
--------------------------------------------------------------------------------

local health_messages = (function()
  local captured = {}
  local names = { "start", "ok", "warn", "error", "info" }
  local original = {}
  for _, name in ipairs(names) do
    original[name] = vim.health[name]
    vim.health[name] = function(msg)
      captured[#captured + 1] = { kind = name, msg = tostring(msg) }
    end
  end
  -- A missing binary short-circuits every probe, so no subprocess runs here.
  config.setup({ cmd = "no-such-herdr-binary-zzz", agents = { auto_start = false } })
  local ok = pcall(require("herdr.health").check)
  for _, name in ipairs(names) do
    vim.health[name] = original[name]
  end
  assert(ok, "health.check() must not throw")
  return captured
end)()

local gate = nil
for _, entry in ipairs(health_messages) do
  if entry.msg:find("Neovim", 1, true) then
    gate = entry
  end
  assert(not entry.msg:find("0.10", 1, true), "no message advertises 0.10 as sufficient")
end
assert(gate ~= nil, "health reports a Neovim version gate")
assert(gate.msg:find("0.11", 1, true), "the gate names 0.11, got: " .. gate.msg)
-- This machine is 0.12.x, so the gate must be satisfied.
assert(vim.fn.has("nvim-0.11") == 1, "test host is 0.11+")
assert(gate.kind == "ok", "a 0.11+ host passes the gate")

print("PASS: F013.6 health gates on Neovim 0.11")

--------------------------------------------------------------------------------
-- 7. open() then hide()/kill() in the same tick must not leave Insert mode
--    pending in the user's own buffer (F004 MAJOR).
--
--    :startinsert only takes effect once control returns to the main loop, so
--    the proof is behavioral: feed keys and check that they were interpreted as
--    commands, not typed into the user's file.
--------------------------------------------------------------------------------

local terminal = require("herdr.terminal")
config.setup({ cmd = "cat", agents = { auto_start = false } })

---@param label string
---@param teardown fun()
local function assert_no_insert_leak(label, teardown)
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  terminal.open()
  teardown()
  -- "x" flushes typeahead now, which is when a pending startinsert would land.
  pcall(vim.api.nvim_feedkeys, "XX", "nx", false)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(
    #lines == 1 and lines[1] == "",
    ("%s must not type into the user's buffer, got %s"):format(label, vim.inspect(lines))
  )
  assert(
    vim.api.nvim_get_mode().mode:sub(1, 1) == "n",
    label .. " leaves the editor in Normal mode, got " .. vim.api.nvim_get_mode().mode
  )

  pcall(vim.cmd, "stopinsert")
  terminal.kill()
  -- Breathe between PTY teardowns: nvim 0.12.4 headless is fragile under
  -- back-to-back terminal kills (see qa-reports/F004.md, upstream SIGHUP).
  vim.wait(150)
end

assert_no_insert_leak("open+hide in one tick", terminal.hide)
assert_no_insert_leak("open+kill in one tick", terminal.kill)

-- Sanity: auto_insert still works when the float is left open. The scheduled
-- startinsert is the whole point, so prove it is still scheduled.
terminal.open()
assert(terminal.is_open(), "open() still opens the float")
vim.wait(200)
terminal.kill()
vim.wait(150)
assert(not terminal.is_open(), "kill() closes the float")
assert(vim.api.nvim_get_mode().mode:sub(1, 1) == "n", "editor ends in Normal mode")

print("PASS: F013.7 no Insert-mode leak from open()+hide()/kill()")

vim.notify = original_notify
print("PASS: F013 Sprint 1 QA regressions")
