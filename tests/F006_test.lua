-- F006: missing-binary guards + :checkhealth herdr
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F006_test.lua" -c "qa!"

local health_mod = require("herdr.health")

-- 1. Real vim.health, real binary path: check() must never throw headlessly.
-- Default cmd is "herdr" (config pre-setup falls back to defaults); this
-- covers real --version and `status` probes when herdr 0.7.5 is installed,
-- and the error-report path if it ever is not. Either way: pcall true.
assert(pcall(health_mod.check), "health.check() must not throw pre-setup with default cmd")

-- Stub vim.health by swapping the module table fields so we can assert on
-- what check() reports. Advice lists are folded into the captured string so
-- hints like the herdr.dev install URL are matchable.
local captured
local health_keys = { "start", "ok", "warn", "error", "info" }
local original_health = {}
for _, key in ipairs(health_keys) do
  original_health[key] = vim.health[key]
end

local function stub_health()
  captured = { start = {}, ok = {}, warn = {}, error = {}, info = {} }
  for _, key in ipairs(health_keys) do
    vim.health[key] = function(...)
      local parts = {}
      for _, arg in ipairs({ ... }) do
        parts[#parts + 1] = type(arg) == "table" and table.concat(arg, " ") or tostring(arg)
      end
      table.insert(captured[key], table.concat(parts, " "))
    end
  end
end

local function restore_health()
  for _, key in ipairs(health_keys) do
    vim.health[key] = original_health[key]
  end
end

local function any_match(reports, pattern)
  for _, msg in ipairs(reports) do
    if msg:match(pattern) then
      return true
    end
  end
  return false
end

local herdr = require("herdr")

-- 2. After setup({}) with the real default cmd: still no throw. When herdr is
-- actually installed this exercises the live --version and `status` probes and
-- must yield at least one ok report; skipped (not failed) on machines without
-- the binary so the suite stays portable.
herdr.setup({})
stub_health()
assert(pcall(health_mod.check), "health.check() must not throw post-setup with default cmd")
if vim.fn.executable("herdr") == 1 then
  assert(#captured.ok >= 1, "real herdr binary produces at least one ok report")
  assert(any_match(captured.ok, "herdr"), "ok report names the herdr binary")
else
  print("SKIP: real `herdr` binary not on $PATH")
end
restore_health()

-- 3. Missing binary: error report carries the herdr.dev install hint,
-- no ok/version report, and check() still returns cleanly.
herdr.setup({ cmd = "no-such-bin-xyz", agents = { auto_start = false } })
stub_health()
assert(pcall(health_mod.check), "health.check() must not throw with missing binary")
assert(#captured.start >= 1 and captured.start[1]:match("herdr"), "start section is herdr.nvim")
assert(any_match(captured.error, "not found"), "missing binary reported as error")
assert(any_match(captured.error, "herdr%.dev"), "error carries the herdr.dev install hint")
assert(not any_match(captured.ok, "version"), "no version ok-report without a binary")
assert(not any_match(captured.ok, "server"), "no server probe without a binary")

-- 4. Stub binary: ok path with version "herdr 0.7.5", server-down warn
-- (herdr-stub `status` prints "status: not running" by default), and the
-- <C-r> redo-shadowing info note (default keymap active).
herdr.setup({ cmd = "herdr-stub", agents = { auto_start = false } })
stub_health()
assert(pcall(health_mod.check), "health.check() must not throw against herdr-stub")
assert(any_match(captured.ok, "herdr%-stub"), "binary-found ok report")
assert(any_match(captured.ok, "herdr 0%.7%.5"), "version ok report shows `herdr 0.7.5`")
assert(any_match(captured.warn, "not running"), "server-down parsed from `status` -> warn")
assert(any_match(captured.warn, ":Herdr"), "server warn points at :Herdr attach")
assert(#captured.error == 0, "no error reports on the stub happy path")
assert(any_match(captured.info, "redo"), "<C-r> info notes redo shadowing")
assert(any_match(captured.info, "keymaps%.toggle"), "info names the escape hatch option")

-- 5. Server-running parse path via the stub's HERDR_STUB_STATUS override.
vim.env.HERDR_STUB_STATUS = "running"
stub_health()
assert(pcall(health_mod.check), "health.check() must not throw with server running")
assert(any_match(captured.ok, "server running"), "server-running ok report")
assert(not any_match(captured.warn, "not running"), "no server-down warn when running")
vim.env.HERDR_STUB_STATUS = nil

-- 6. No info note when the toggle keymap is not the redo-shadowing default.
herdr.setup({ cmd = "herdr-stub", keymaps = { toggle = false }, agents = { auto_start = false } })
stub_health()
assert(pcall(health_mod.check), "health.check() must not throw with toggle=false")
assert(#captured.info == 0, "no redo info note when toggle is not <C-r>")

-- 7. Sub-second poll interval is a warn (subprocess spawn cost), and the
-- default 5000ms interval is not.
herdr.setup({
  cmd = "herdr-stub",
  keymaps = { toggle = false },
  agents = { auto_start = false, poll_interval_ms = 250 },
})
stub_health()
assert(pcall(health_mod.check), "health.check() must not throw with a tiny poll interval")
assert(any_match(captured.warn, "poll_interval_ms"), "sub-second poll interval warns")

herdr.setup({ cmd = "herdr-stub", keymaps = { toggle = false }, agents = { auto_start = false } })
stub_health()
assert(pcall(health_mod.check), "health.check() must not throw at the default poll interval")
assert(not any_match(captured.warn, "poll_interval_ms"), "default poll interval does not warn")
restore_health()

-- 8. :checkhealth herdr resolves: nvim's health system loads
-- lua/<name>/health.lua and calls check(), so the file location plus a real
-- :checkhealth run are what prove the entry point wires up.
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
assert(
  vim.fn.filereadable(plugin_root .. "/lua/herdr/health.lua") == 1,
  "lua/herdr/health.lua exists where :checkhealth herdr looks for it"
)
assert(type(health_mod.check) == "function", "health module exposes check()")

local bufs_before_checkhealth = vim.api.nvim_list_bufs()
local ok_checkhealth, checkhealth_err = pcall(vim.cmd, "checkhealth herdr")
assert(ok_checkhealth, "checkhealth herdr does not error: " .. tostring(checkhealth_err))
-- Wipe the report buffer(s) so the rest of the test counts windows/buffers
-- against a clean baseline.
local before_lookup = {}
for _, buf in ipairs(bufs_before_checkhealth) do
  before_lookup[buf] = true
end
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if not before_lookup[buf] and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

-- 9. Guard path through :Herdr / :HerdrOpen: missing binary means a single
-- ERROR notify pointing at checkhealth and NO window or buffer created.
local notifications = {}
local original_notify = vim.notify
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end

herdr.setup({ cmd = "no-such-bin-xyz", agents = { auto_start = false } })
local wins_before = #vim.api.nvim_list_wins()
local bufs_before = #vim.api.nvim_list_bufs()
local notify_before = #notifications

vim.cmd("HerdrOpen")
assert(#vim.api.nvim_list_wins() == wins_before, ":HerdrOpen creates no window with missing binary")
assert(#vim.api.nvim_list_bufs() == bufs_before, ":HerdrOpen creates no buffer with missing binary")
assert(#notifications == notify_before + 1, ":HerdrOpen notifies exactly once")
local guard = notifications[#notifications]
assert(
  guard.msg:lower():match("not found") and guard.msg:match("checkhealth"),
  "guard notify mentions not found and points at :checkhealth"
)
assert(guard.level == vim.log.levels.ERROR, "guard notify is ERROR level")

-- :Herdr (toggle) hits the same guard
notify_before = #notifications
vim.cmd("Herdr")
assert(#vim.api.nvim_list_wins() == wins_before, ":Herdr creates no window with missing binary")
assert(#notifications == notify_before + 1, ":Herdr notifies the guard message")

local terminal = require("herdr.terminal")
assert(not terminal.is_open(), "terminal reports closed after guarded opens")
assert(not terminal.is_running(), "no job started by guarded opens")

-- 10. cli.run() with a missing binary delivers cb(nil, err) async, no throw.
local cli = require("herdr.cli")
local run_out, run_err
local ok_run = pcall(cli.run, { "agent", "list" }, function(out, err)
  run_out, run_err = out, err
end)
assert(ok_run, "cli.run() must not throw with missing binary")
assert(vim.wait(2000, function()
  return run_err ~= nil
end), "cli.run() error callback delivered")
assert(run_out == nil, "cli.run() passes nil out on missing binary")
assert(type(run_err) == "string" and run_err:match("not found"), "cli.run() err names the problem")

-- 11. Polling must not blow up setup() with a missing binary. herdr.agents
-- ships in F007, so today this asserts init.setup()'s pcall-tolerant
-- auto_start path: no error, and status() reports polling off. The
-- agents-specific refusal is asserted in F007 once the module exists.
assert(
  pcall(herdr.setup, { cmd = "no-such-bin-xyz", agents = { auto_start = true } }),
  "setup() with auto_start and a missing binary raises no error"
)
assert(herdr.status().agents.polling == false, "no polling active with a missing binary")

local ok_agents, agents = pcall(require, "herdr.agents")
if ok_agents then
  agents.start()
  assert(agents.is_polling() == false, "polling refuses to start with missing binary")
end

-- Clean exit: no stray terminal buffer, job, or float from the guard paths.
terminal.kill()
assert(not terminal.is_running(), "no herdr job left running at test end")
assert(not terminal.is_open(), "no herdr float left open at test end")

vim.notify = original_notify
print("PASS: F006 missing-binary guards and health check")
