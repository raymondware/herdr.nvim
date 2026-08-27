-- F005: init.lua facade - setup(), user commands, keymaps, status()
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F005_test.lua" -c "qa!"

-- Capture notifications for the whole run: guard messages, graceful agent
-- fallbacks, and :HerdrStatus all go through vim.notify.
local notifications = {}
local original_notify = vim.notify
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
end
local function last_notification()
  return notifications[#notifications]
end

-- 1. Pre-setup state: reminder command present, guard active, nothing loaded
assert(vim.fn.exists(":HerdrSetup") == 2, ":HerdrSetup present before setup()")
assert(package.loaded["herdr.agents"] == nil, "herdr.agents must not be loaded")

local herdr = require("herdr")
local count_before = #notifications
herdr.toggle()
assert(#notifications == count_before + 1, "pre-setup toggle() notifies")
assert(last_notification().msg:match("setup"), "guard message points at setup()")
assert(last_notification().level == vim.log.levels.WARN, "guard notifies at WARN")

-- 2. setup(): cmd="cat" is a real binary. agents.auto_start defaults to true,
-- so setup() loads herdr.agents and arms the poll timer BY DESIGN (F007).
herdr.setup({ cmd = "cat" })
assert(package.loaded["herdr.agents"] ~= nil, "auto_start loads herdr.agents")
assert(require("herdr.agents").is_polling(), "auto_start arms the poll timer")

local cmds = vim.api.nvim_get_commands({})
for _, name in ipairs({ "Herdr", "HerdrOpen", "HerdrClose", "HerdrKill", "HerdrAgents", "HerdrStatus", "HerdrPoll" }) do
  assert(cmds[name] ~= nil, "command :" .. name .. " registered")
  assert(vim.fn.exists(":" .. name) == 2, "exists(:" .. name .. ") == 2")
end
assert(cmds["HerdrSetup"] == nil, ":HerdrSetup reminder deleted by setup()")

-- 3. Default keymap applied
assert(vim.fn.maparg("<C-r>", "n") ~= "", "default <C-r> toggle map set")

-- 4. keymaps.toggle = false leaves the mapping alone (lazy keys spec owns it).
-- Maps persist within one headless run, so delete the default first and
-- prove a toggle=false re-setup does not recreate it.
vim.keymap.del("n", "<C-r>")
herdr.setup({ cmd = "cat", keymaps = { toggle = false } })
assert(vim.fn.maparg("<C-r>", "n") == "", "toggle=false skips the keymap")

-- keymaps.agents string maps when provided
herdr.setup({ cmd = "cat", keymaps = { agents = "<leader>ha" } })
assert(vim.fn.maparg("<leader>ha", "n") ~= "", "keymaps.agents string maps to M.agents")
assert(vim.fn.maparg("<C-r>", "n") ~= "", "default toggle map restored by re-setup")

-- 5. Repeated setup() is idempotent (no E174, commands still there once)
local ok_again = pcall(herdr.setup, { cmd = "cat" })
assert(ok_again, "second setup() call must not error")
assert(vim.fn.exists(":Herdr") == 2, ":Herdr survives re-setup")

-- 6. Herdr augroup with the VimLeavePre cleanup hook
local autocmds = vim.api.nvim_get_autocmds({ group = "Herdr", event = "VimLeavePre" })
assert(#autocmds >= 1, "Herdr augroup has a VimLeavePre autocmd")

-- 7. status() shape before any terminal use
local s = herdr.status()
assert(type(s) == "table", "status() returns a table")
assert(s.available == true, "status().available true with cmd=cat")
assert(s.cmd == "cat", "status().cmd reports the configured binary")
assert(type(s.terminal) == "table", "status().terminal is a table")
assert(s.terminal.open == false, "terminal closed before open")
assert(s.terminal.running == false, "no job before open")
assert(type(s.agents) == "table", "status().agents is a table")
-- Post-F007: the agents subtable is wired to the real polling engine, so
-- polling mirrors the live timer and counts() always returns all six keys.
local agents = require("herdr.agents")
assert(s.agents.polling == agents.is_polling(), "agents.polling mirrors the real timer")
assert(s.agents.polling == true, "polling is on after an auto_start setup()")
assert(type(s.agents.counts) == "table", "agents.counts is a table")
for _, key in ipairs({ "working", "blocked", "done", "idle", "unknown", "total" }) do
  assert(type(s.agents.counts[key]) == "number", "agents.counts." .. key .. " is a number")
end
assert(s.agents.degraded == false, "agents.degraded false before any poll failed")

-- 8. Command-driven terminal lifecycle: :Herdr opens the float
vim.cmd("Herdr")
local terminal = require("herdr.terminal")
assert(terminal.is_open(), ":Herdr opens the float")
local win_cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
assert(win_cfg.relative == "editor", "toggled window is an editor float")

s = herdr.status()
assert(s.terminal.open == true, "status() sees the open terminal")
assert(s.terminal.running == true, "status() sees the running job")

-- :HerdrClose hides but keeps the job (persist_buffer default)
vim.cmd("HerdrClose")
assert(not terminal.is_open(), ":HerdrClose hides the float")
assert(terminal.is_running(), "job survives :HerdrClose")

-- :HerdrKill tears everything down
vim.cmd("HerdrKill")
assert(not terminal.is_open(), ":HerdrKill closes the float")
assert(not terminal.is_running(), ":HerdrKill stops the job")

-- 9. :HerdrStatus notifies an INFO summary
count_before = #notifications
vim.cmd("HerdrStatus")
assert(#notifications == count_before + 1, ":HerdrStatus notifies")
assert(last_notification().msg:match("herdr"), "status summary mentions herdr")
assert(last_notification().level == vim.log.levels.INFO, "status summary is INFO")

-- 10. :HerdrAgents and :HerdrPoll are real now that F007/F009 shipped, so
-- assert the actual behavior (float opens, polling toggles) instead of the
-- old "not yet available" fallback notify.
local agents_ui = require("herdr.agents_ui")
local ok_agents = pcall(vim.cmd, "HerdrAgents")
assert(ok_agents, ":HerdrAgents must not error")
assert(agents_ui.is_open(), ":HerdrAgents opens the agent float")
assert(pcall(vim.cmd, "HerdrAgents"), ":HerdrAgents must not error when toggling closed")
assert(not agents_ui.is_open(), ":HerdrAgents toggles the agent float closed")

vim.cmd("HerdrPoll stop")
assert(not agents.is_polling(), ":HerdrPoll stop stops polling")
vim.cmd("HerdrPoll start")
assert(agents.is_polling(), ":HerdrPoll start starts polling")
vim.cmd("HerdrPoll")
assert(not agents.is_polling(), ":HerdrPoll with no argument toggles polling off")
vim.cmd("HerdrPoll toggle")
assert(agents.is_polling(), ":HerdrPoll toggle turns polling back on")

-- Invalid poll action is rejected before any module lookup
count_before = #notifications
pcall(vim.cmd, "HerdrPoll bogus")
assert(#notifications == count_before + 1, "invalid poll action notifies")
assert(last_notification().msg:match("invalid"), "invalid poll action message")

-- 11. :HerdrPoll completion offers the three actions
local completions = vim.fn.getcompletion("HerdrPoll ", "cmdline")
for _, word in ipairs({ "start", "stop", "toggle" }) do
  assert(vim.tbl_contains(completions, word), "HerdrPoll completes " .. word)
end

vim.notify = original_notify
print("PASS: F005 init facade, commands, keymaps, status")
