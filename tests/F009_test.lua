-- F009: :HerdrAgents float (render, extmarks, keymaps, unsubscribe, empty and
-- degraded states) plus the hl.lua highlight groups and extmark namespace.
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F009_test.lua" -c "qa!"
--
-- A clean exit is part of the assertion set: a leaked listener or uv timer
-- would hang this script under the runner timeout.

local agents = require("herdr.agents")
local config = require("herdr.config")
local hl = require("herdr.hl")
local ui = require("herdr.agents_ui")

-- Degradation warns; keep headless output to the PASS line.
local original_notify = vim.notify
vim.notify = function() end

-- Leak instrumentation. agents_ui looks up on_update on the module table at
-- call time, so patching the field counts exactly the UI's subscriptions.
-- Test-local listeners use real_on_update so they never skew the counters.
local real_on_update = agents.on_update
local subs, unsubs = 0, 0
agents.on_update = function(fn)
  subs = subs + 1
  local unsubscribe = real_on_update(fn)
  return function()
    unsubs = unsubs + 1
    unsubscribe()
  end
end

local function float_win()
  local win = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_config(win).relative == "editor", "current window is the float")
  return win, vim.api.nvim_win_get_buf(win)
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function hl_groups(buf)
  local groups = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, hl.ns, 0, -1, { details = true })) do
    local details = mark[4]
    if details and details.hl_group then
      groups[details.hl_group] = (groups[details.hl_group] or 0) + 1
    end
  end
  return groups
end

local function keymap_lhs(buf)
  local found = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    found[map.lhs] = map
  end
  return found
end

-- 1. hl.lua: the namespace is stable and the five groups resolve to their
-- default links (a user colorscheme is allowed to override them, which is why
-- they are created with default = true).
assert(type(hl.ns) == "number", "hl.ns is an extmark namespace id")
assert(hl.ns == vim.api.nvim_create_namespace("herdr"), "hl.ns is the 'herdr' namespace")
assert(hl.get_ns() == hl.ns, "hl.get_ns() returns the same namespace")

local EXPECTED_LINKS = {
  HerdrAgentWorking = "DiagnosticWarn",
  HerdrAgentBlocked = "DiagnosticError",
  HerdrAgentDone = "DiagnosticOk",
  HerdrAgentIdle = "Comment",
  HerdrHeader = "Title",
}

hl.setup()
hl.setup() -- idempotent
for name, link in pairs(EXPECTED_LINKS) do
  local def = vim.api.nvim_get_hl(0, { name = name })
  assert(not vim.tbl_isempty(def), name .. " is defined")
  assert(def.link == link, ("%s links to %s, got %s"):format(name, link, tostring(def.link)))
end
assert(
  #vim.api.nvim_get_autocmds({ group = "HerdrHl", event = "ColorScheme" }) == 1,
  "exactly one ColorScheme re-apply autocmd after two setup() calls"
)

-- 2. Empty state, asserted before any successful poll has landed: the cache is
-- empty at script start, and the float paints synchronously inside open().
-- agents.enabled = false also proves open() honors the flag (no polling).
config.setup({ cmd = "herdr-stub-fail", agents = { enabled = false, poll_interval_ms = 100 } })
assert(not ui.is_open(), "float is closed before the first open()")
ui.open()
assert(ui.is_open(), "open() creates the float")

local empty_win, empty_buf = float_win()
local empty_lines = vim.api.nvim_buf_get_lines(empty_buf, 0, -1, false)
assert(empty_lines[1]:match("0 agents"), "header counts zero agents: " .. empty_lines[1])
assert(text(empty_buf):match("No agents"), "empty cache renders the placeholder")
assert(not agents.is_polling(), "open() does not poll when agents.enabled is false")
assert(vim.bo[empty_buf].buftype == "nofile", "float buffer is a scratch nofile buffer")
assert(vim.bo[empty_buf].bufhidden == "wipe", "float buffer wipes itself")
assert(vim.bo[empty_buf].modifiable == false, "float buffer is read-only after render")
assert(vim.api.nvim_win_get_config(empty_win).style == "minimal", "float uses style=minimal")
assert(subs == 1 and unsubs == 0, "open() subscribed exactly once")
ui.close()
assert(not ui.is_open(), "close() closes the float")
assert(subs == 1 and unsubs == 1, "close() released the subscription")
assert(not vim.api.nvim_buf_is_valid(empty_buf), "float buffer is wiped on close")
assert(pcall(ui.close), "close() twice is safe")
assert(unsubs == 1, "second close() does not double-unsubscribe")
assert(pcall(ui.render), "render() with no float is a no-op")

-- 3. Happy path against herdr-stub: 3 agents (working claude-1, blocked codex
-- via the display_agent fallback, done reviewer).
config.setup({ cmd = "herdr-stub", agents = { auto_start = false, poll_interval_ms = 100 } })
-- Re-issued every 100ms because the failed poll from section 2 may still be in
-- flight, and agents.refresh() coalesces onto an in-flight request instead of
-- spawning a second one.
assert(vim.wait(5000, function()
  if agents.counts().total == 3 then
    return true
  end
  agents.refresh()
  return false
end, 100), "stub data reaches the agents cache")

ui.open()
local list_win, list_buf = float_win()
local body = text(list_buf)
-- Plain find (not match): agent names contain "-", which is a pattern quantifier.
for _, name in ipairs({ "claude-1", "codex", "reviewer" }) do
  assert(body:find(name, 1, true), "float lists agent " .. name)
end
for _, agent_state in ipairs({ "working", "blocked", "done" }) do
  assert(body:find(agent_state, 1, true), "float shows state " .. agent_state)
end
local header = vim.api.nvim_buf_get_lines(list_buf, 0, 1, false)[1]
assert(header:match("3 agents"), "header reports the agent total: " .. header)
assert(header:match("1 working") and header:match("1 blocked") and header:match("1 done"),
  "header reports per-state counts: " .. header)
assert(agents.is_polling(), "open() starts polling when agents.enabled is true")
-- F015 groups the rows under a per-workspace header. herdr-stub puts all three
-- agents in w1 and answers nothing for `workspace list`, so the group renders
-- under its raw id (the labelled and multi-workspace cases are F015's).
assert(body:find(" w1", 1, true), "rows are grouped under a workspace header: " .. body)

-- 4. Extmarks live in the single herdr namespace, one per state plus the header.
local groups = hl_groups(list_buf)
for _, group in ipairs({ "HerdrAgentWorking", "HerdrAgentBlocked", "HerdrAgentDone", "HerdrHeader" }) do
  assert(groups[group], "extmark present for " .. group .. ", got " .. vim.inspect(groups))
end
-- One HerdrHeader for the global count line plus one per workspace title, and
-- herdr-stub has exactly one workspace.
assert(
  groups.HerdrHeader == 2,
  "one header extmark for the global line plus one per workspace title, got "
    .. tostring(groups.HerdrHeader)
)

-- 5. Buffer-local keymaps: q / <Esc> close, r refreshes, <CR> opens the detail
-- float (F011 owns the detail behavior; F009 only asserts the mapping exists).
local maps = keymap_lhs(list_buf)
assert(maps.q, "q is mapped in the float buffer")
assert(maps.r, "r is mapped in the float buffer")
assert(vim.fn.maparg("q", "n", false, true).buffer == 1, "q is buffer-local")
assert(vim.fn.maparg("r", "n", false, true).buffer == 1, "r is buffer-local")
assert(vim.fn.maparg("<Esc>", "n", false, true).buffer == 1, "<Esc> is buffer-local")
assert(maps["<CR>"], "<CR> is mapped in the float buffer")
assert(vim.fn.maparg("<CR>", "n", false, true).buffer == 1, "<CR> is buffer-local")
assert(type(maps["<CR>"].callback) == "function", "<CR> is a Lua callback mapping")

-- 6. r re-renders in place with fresh data: herdr-stub-v2 returns one agent
-- named "solo", so the previous names must disappear from the same buffer.
config.setup({ cmd = "herdr-stub-v2", agents = { auto_start = false, poll_interval_ms = 100 } })
maps.r.callback()
assert(vim.wait(5000, function()
  return text(list_buf):find("solo", 1, true) ~= nil
end, 20), "r triggers a re-render with the new data")
local refreshed = text(list_buf)
assert(not refreshed:find("claude-1", 1, true), "stale agents are gone after re-render")
assert(not refreshed:find("reviewer", 1, true), "stale agents are gone after re-render")
local solo_header = vim.api.nvim_buf_get_lines(list_buf, 0, 1, false)[1]
assert(solo_header:match("1 agent%f[%A]"), "header re-rendered and pluralizes: " .. solo_header)
assert(vim.bo[list_buf].modifiable == false, "buffer is read-only again after re-render")
assert(vim.api.nvim_win_get_buf(list_win) == list_buf, "re-render happened in place")
assert(subs == 2 and unsubs == 1, "re-render did not add a subscription")

-- 7. Closing the window behind the module's back must release the listener
-- (WinClosed / BufWipeout teardown), and later polls must not touch the wiped
-- buffer or throw.
local ticks = 0
local unsub_ticks = real_on_update(function()
  ticks = ticks + 1
end)
vim.api.nvim_win_close(list_win, true)
assert(not ui.is_open(), "is_open() false after an external window close")
assert(unsubs == 2, "external close released the UI subscription")
assert(not vim.api.nvim_buf_is_valid(list_buf), "external close wiped the float buffer")

local before_ticks = ticks
agents.refresh()
assert(vim.wait(5000, function()
  return ticks > before_ticks
end, 20), "polling keeps working after the float is gone")
assert(pcall(ui.render), "render() after an external close is a no-op")
assert(pcall(ui.close), "close() after an external close is safe")
unsub_ticks()

-- Polling survives close() on purpose: the lualine component still wants it.
assert(agents.is_polling(), "close() must not stop polling")

-- 8. 10 open/close cycles leak neither buffers nor listeners.
local buffers_before = #vim.api.nvim_list_bufs()
local subs_before = subs
for i = 1, 10 do
  ui.open()
  assert(ui.is_open(), "cycle " .. i .. ": float opened")
  ui.close()
  assert(not ui.is_open(), "cycle " .. i .. ": float closed")
end
assert(
  #vim.api.nvim_list_bufs() == buffers_before,
  ("10 open/close cycles leaked %d buffers"):format(#vim.api.nvim_list_bufs() - buffers_before)
)
assert(subs == subs_before + 10 and unsubs == subs, "every cycle unsubscribed: " .. subs .. "/" .. unsubs)

-- 9. toggle() opens then closes.
ui.toggle()
assert(ui.is_open(), "toggle() opens the float")
ui.toggle()
assert(not ui.is_open(), "toggle() closes the float")
assert(unsubs == subs, "toggle() leaves no subscription behind")

-- 10. Degraded polling is visible in the float. max_failures = 1 degrades on
-- the first failed poll; the float is asserted on the synchronous first render,
-- before open()'s agents.start() re-arms anything.
agents.stop()
config.setup({
  cmd = "herdr-stub-fail",
  agents = { auto_start = false, poll_interval_ms = 50, max_failures = 1 },
})
agents.start()
assert(vim.wait(5000, function()
  return agents.is_degraded()
end, 20), "failing stub degrades polling")
local last_error = agents.last_error()
assert(type(last_error) == "string", "last_error() is set while degraded")

ui.open()
local _, degraded_buf = float_win()
local degraded_body = text(degraded_buf)
assert(degraded_body:match("polling stopped"), "degraded float explains that polling stopped")
assert(degraded_body:match("server"), "degraded float shows last_error(): " .. degraded_body)
ui.close()
agents.stop()

-- 11. The degraded notice is inserted ABOVE the agent rows, so every agent
-- shifts down one line while the cursor stays where the user left it. render()
-- must carry the cursor to the agent it was on, or <CR> silently addresses a row
-- the user did not pick - the notice line (a no-op on what looks like the
-- selected agent) or, once the notice clears, a different agent.
config.setup({ cmd = "herdr-stub", agents = { auto_start = false, poll_interval_ms = 100 } })
assert(vim.wait(5000, function()
  if agents.counts().total == 3 then
    return true
  end
  agents.refresh()
  return false
end, 100), "three agents cached again for the row-shift test")

--- 1-based buffer line containing `needle`, or nil.
local function row_of(buf, needle)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return i
    end
  end
end

--- Window title as plain text (nvim returns it as {text, hl} chunks).
local function title_text(win)
  local title = vim.api.nvim_win_get_config(win).title
  if type(title) == "string" then
    return title
  end
  local parts = {}
  for _, chunk in ipairs(title or {}) do
    parts[#parts + 1] = chunk[1]
  end
  return table.concat(parts)
end

ui.open()
local shift_win, shift_buf = float_win()
-- The last agent has the most rows above it, so a shift is unmistakable.
local before_row = row_of(shift_buf, "reviewer")
assert(before_row, "reviewer is rendered before degradation")
vim.api.nvim_win_set_cursor(shift_win, { before_row, 0 })

config.setup({
  cmd = "herdr-stub-fail",
  agents = { auto_start = false, poll_interval_ms = 50, max_failures = 1 },
})
agents.start()
assert(vim.wait(5000, function()
  return agents.is_degraded()
end, 20), "polling degrades while the float is open")

-- The failed poll keeps the cache, so the same three agents are still listed -
-- one line lower, because the notice went in above them.
local after_row = row_of(shift_buf, "reviewer")
assert(
  after_row == before_row + 1,
  ("the degraded notice pushed the agent rows down: %s -> %s"):format(
    tostring(before_row),
    tostring(after_row)
  )
)
assert(
  vim.api.nvim_win_get_cursor(shift_win)[1] == after_row,
  ("the cursor followed the agent it was on: row %d, agent at %d"):format(
    vim.api.nvim_win_get_cursor(shift_win)[1],
    after_row
  )
)

-- The end of the contract: <CR> still opens the agent the user selected.
local shift_maps = keymap_lhs(shift_buf)
shift_maps["<CR>"].callback()
assert(ui.detail_is_open(), "<CR> still resolves an agent after the row shift")
assert(
  title_text(vim.api.nvim_get_current_win()):find("reviewer", 1, true),
  "the detail float targets the selected agent, not the notice line: "
    .. title_text(vim.api.nvim_get_current_win())
)
ui.detail_close()

-- And back: recovery removes the notice, so the rows shift up again and the
-- cursor has to come with them.
config.setup({ cmd = "herdr-stub", agents = { auto_start = false, poll_interval_ms = 100 } })
agents.start()
assert(vim.wait(5000, function()
  return not agents.is_degraded() and row_of(shift_buf, "polling stopped") == nil
end, 20), "recovery clears the degraded notice")
assert(
  vim.api.nvim_win_get_cursor(shift_win)[1] == row_of(shift_buf, "reviewer"),
  "the cursor followed the agent back up when the notice cleared"
)
agents.stop()
ui.close()

-- 12. Teardown: no listeners, no timer, no float. Anything left would hang the
-- headless exit or fail the leak counters above.
agents.cleanup()
assert(not agents.is_polling(), "no polling left at test end")
assert(not ui.is_open(), "no float left at test end")
assert(subs == unsubs, "no leaked agents.on_update subscription: " .. subs .. "/" .. unsubs)

agents.on_update = real_on_update
vim.notify = original_notify
print("PASS: F009 agents list float, extmarks, keymaps and highlight groups")
