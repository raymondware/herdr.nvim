-- F011: the <CR> agent detail float (second, smaller, independent float fed by
-- one `herdr agent get`), its keymaps, the non-agent-line no-ops, teardown with
-- the list, and the error path.
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F011_test.lua" -c "qa!"
--
-- A clean exit is part of the assertion set: an orphaned window, a leaked
-- listener or a leaked uv timer would hang this script under the runner timeout.

local agents = require("herdr.agents")
local cli = require("herdr.cli")
local config = require("herdr.config")
local ui = require("herdr.agents_ui")

-- Degradation warns in the error-path section; keep headless output to the PASS
-- line.
local original_notify = vim.notify
vim.notify = function() end

-- Leak instrumentation, same seam F009 uses: agents_ui looks up on_update on the
-- module table at call time. The detail float is a snapshot and must NOT add a
-- subscription of its own.
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

--- Every floating window, in a stable order.
---@return integer[]
local function float_wins()
  local found = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative == "editor" then
      found[#found + 1] = win
    end
  end
  table.sort(found)
  return found
end

local function float_count()
  return #float_wins()
end

---@param exclude integer window to skip
---@return integer|nil
local function other_float(exclude)
  for _, win in ipairs(float_wins()) do
    if win ~= exclude then
      return win
    end
  end
  return nil
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function keymap_lhs(buf)
  local found = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    found[map.lhs] = map
  end
  return found
end

--- Real keyboard path, not just a callback call.
---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- 1-based buffer line of the first line containing `needle` (plain find).
---@param buf integer
---@param needle string
---@return integer
local function line_of(buf, needle)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return i
    end
  end
  error("no line containing " .. needle)
end

-- 1. Populate the cache from herdr-stub, then open the list.
config.setup({ cmd = "herdr-stub", agents = { auto_start = false, poll_interval_ms = 100 } })
-- Re-issued because refresh() coalesces onto an in-flight request rather than
-- spawning a second one.
assert(vim.wait(5000, function()
  if agents.counts().total == 3 then
    return true
  end
  agents.refresh()
  return false
end, 100), "stub data reaches the agents cache")

assert(float_count() == 0, "no floats before open()")
ui.open()
assert(ui.is_open(), "open() creates the list float")
local list_win = vim.api.nvim_get_current_win()
local list_buf = vim.api.nvim_win_get_buf(list_win)
assert(float_count() == 1, "exactly one float while only the list is up")
assert(not ui.detail_is_open(), "no detail float yet")

-- 2. <CR> is mapped, buffer-local, in the list float (F009 left it for F011).
local maps = keymap_lhs(list_buf)
assert(maps["<CR>"], "<CR> is mapped in the list buffer")
assert(vim.fn.maparg("<CR>", "n", false, true).buffer == 1, "<CR> is buffer-local")
assert(type(maps["<CR>"].callback) == "function", "<CR> is a Lua callback mapping")
assert(maps.q and maps.r, "the F009 mappings survive")

-- 3. Real keyboard path: cursor on the claude-1 row, then <CR>.
local claude_line = line_of(list_buf, "claude-1")
-- Global header, separator, the w1 workspace header (F015 grouping), then the
-- rows worst state first: blocked codex, working claude-1, done reviewer.
assert(claude_line == 5, "grouping puts claude-1 on line 5, got " .. claude_line)
vim.api.nvim_win_set_cursor(list_win, { claude_line, 0 })
feed("\r")

assert(vim.wait(5000, function()
  return float_count() == 2
end, 20), "<CR> opens a second float")
assert(ui.detail_is_open(), "detail_is_open() true after <CR>")
local detail_win = other_float(list_win)
assert(detail_win, "found the detail window")
local detail_buf = vim.api.nvim_win_get_buf(detail_win)
assert(vim.api.nvim_get_current_win() == detail_win, "<CR> focuses the detail float")
assert(ui.is_open(), "the list float is still open")
assert(vim.api.nvim_buf_is_valid(list_buf), "the list buffer is untouched")

-- 4. Content comes from the `agent get` envelope, not from the list row.
assert(vim.wait(5000, function()
  return text(detail_buf):find("/tmp/project", 1, true) ~= nil
end, 20), "agent get lands in the detail float: " .. text(detail_buf))
local body = text(detail_buf)
-- Plain find: agent names contain "-", which is a pattern quantifier.
for _, needle in ipairs({ "claude-1", "working", "claude", "p1", "tb1", "w1", "t1", "/tmp/project" }) do
  assert(body:find(needle, 1, true), ("detail float shows %q: %s"):format(needle, body))
end
assert(body:find("name:", 1, true), "fields render as key: value")
assert(body:find("cwd:", 1, true), "cwd is labelled")
assert(body:find("focused:", 1, true), "focused is labelled")
assert(not body:find("loading", 1, true), "the loading placeholder was replaced")

-- 5. Window and buffer properties: smaller than the list, centered, scratch,
-- read-only, self-wiping, titled after the agent, drawn above the list.
local list_cfg = vim.api.nvim_win_get_config(list_win)
local detail_cfg = vim.api.nvim_win_get_config(detail_win)
assert(detail_cfg.relative == "editor", "the detail float is editor-relative")
assert(detail_cfg.style == "minimal", "the detail float uses style=minimal")
assert(detail_cfg.border ~= nil and detail_cfg.border ~= "none", "the detail float has a border")
assert(detail_cfg.width < list_cfg.width, ("detail is narrower: %d < %d"):format(detail_cfg.width, list_cfg.width))
assert(detail_cfg.height < list_cfg.height, ("detail is shorter: %d < %d"):format(detail_cfg.height, list_cfg.height))
assert(detail_cfg.zindex > list_cfg.zindex, "the detail float draws above the list")
-- Centered on the editor: the same formula the list uses, so both are centered.
assert(
  detail_cfg.col == math.floor((vim.o.columns - detail_cfg.width - 2) / 2),
  "the detail float is horizontally centered"
)
local title = detail_cfg.title
assert(type(title) == "table" and title[1][1]:find("claude-1", 1, true), "title names the agent: " .. vim.inspect(title))
assert(vim.bo[detail_buf].buftype == "nofile", "the detail buffer is a scratch nofile buffer")
assert(vim.bo[detail_buf].bufhidden == "wipe", "the detail buffer wipes itself")
assert(vim.bo[detail_buf].modifiable == false, "the detail buffer is read-only")
assert(detail_buf ~= list_buf, "the detail float owns its own buffer")

-- 6. The detail float is a SNAPSHOT: no on_update subscription of its own.
assert(subs == 1 and unsubs == 0, "only the list subscribed: " .. subs .. "/" .. unsubs)

-- 7. q closes ONLY the detail float and hands focus back to the list.
feed("q")
assert(vim.wait(5000, function()
  return float_count() == 1
end, 20), "q in the detail float closes it")
assert(not ui.detail_is_open(), "detail_is_open() false after q")
assert(ui.is_open(), "q in the detail float leaves the list open")
assert(vim.api.nvim_buf_is_valid(list_buf), "the list buffer survives the detail close")
assert(not vim.api.nvim_buf_is_valid(detail_buf), "the detail buffer is wiped")
assert(vim.api.nvim_get_current_win() == list_win, "focus returned to the list float")
assert(pcall(ui.detail_close), "detail_close() twice is safe")
assert(float_count() == 1, "the redundant detail_close() left the list alone")

-- 8. <Esc> closes the detail float too, and the public detail_open() is the same
-- entry point the mapping uses (cursor is still on the claude-1 row).
ui.detail_open()
assert(ui.detail_is_open(), "detail_open() with no argument resolves the cursor line")
assert(float_count() == 2, "detail_open() opened the second float")
feed("<Esc>")
assert(vim.wait(5000, function()
  return float_count() == 1
end, 20), "<Esc> in the detail float closes it")
assert(ui.is_open(), "<Esc> in the detail float leaves the list open")

-- 9. The mapped callback itself, invoked directly, and on a different row.
local reviewer_line = line_of(list_buf, "reviewer")
vim.api.nvim_win_set_cursor(list_win, { reviewer_line, 0 })
maps["<CR>"].callback()
assert(ui.detail_is_open(), "the mapped callback opens the detail float")
local retarget_win = other_float(list_win)
local retarget_title = vim.api.nvim_win_get_config(retarget_win).title
assert(retarget_title[1][1]:find("reviewer", 1, true), "the title follows the cursor row: " .. vim.inspect(retarget_title))
-- Re-triggering retargets in place instead of stacking floats.
vim.api.nvim_win_set_cursor(list_win, { claude_line, 0 })
ui.detail_open()
assert(float_count() == 2, "re-triggering <CR> does not stack a third float")
assert(
  vim.api.nvim_win_get_config(other_float(list_win)).title[1][1]:find("claude-1", 1, true),
  "the retargeted float shows the new agent"
)
ui.detail_close()
assert(float_count() == 1, "back to just the list")

-- 10. The global header, the separator and the workspace header line (line 3
-- since F015 grouping) are harmless no-ops.
for _, lnum in ipairs({ 1, 2, 3 }) do
  vim.api.nvim_win_set_cursor(list_win, { lnum, 0 })
  local before = float_count()
  feed("\r")
  assert(float_count() == before, "<CR> on line " .. lnum .. " opened nothing")
  assert(not ui.detail_is_open(), "<CR> on line " .. lnum .. " is a no-op")
  assert(pcall(ui.detail_open), "detail_open() on line " .. lnum .. " does not throw")
  assert(float_count() == before, "detail_open() on line " .. lnum .. " opened nothing")
end

-- 11. Empty-state and degraded lines are no-ops too. Patched on the module table
-- (the same seam F010 uses) so both are reachable deterministically without
-- driving the poller into those states while a float is up.
local real_get, real_counts = agents.get, agents.counts
local real_is_degraded, real_last_error = agents.is_degraded, agents.last_error
agents.get = function()
  return {}
end
agents.counts = function()
  return { working = 0, blocked = 0, done = 0, idle = 0, unknown = 0, total = 0 }
end
agents.is_degraded = function()
  return true
end
agents.last_error = function()
  return "herdr server not running"
end
ui.render()
local placeholder = text(list_buf)
assert(placeholder:find("polling stopped", 1, true), "the degraded notice rendered")
assert(placeholder:find("No agents", 1, true), "the empty-state placeholder rendered")
for _, needle in ipairs({ "polling stopped", "No agents" }) do
  vim.api.nvim_win_set_cursor(list_win, { line_of(list_buf, needle), 0 })
  feed("\r")
  assert(float_count() == 1, ("<CR> on the %q line opened nothing"):format(needle))
  assert(not ui.detail_is_open(), ("<CR> on the %q line is a no-op"):format(needle))
end
agents.get, agents.counts = real_get, real_counts
agents.is_degraded, agents.last_error = real_is_degraded, real_last_error
ui.render()
assert(text(list_buf):find("claude-1", 1, true), "the real list is back")

-- 12. Closing the list must take a lingering detail float with it, both via
-- close() and via an external window close (no orphaned windows either way).
vim.api.nvim_win_set_cursor(list_win, { claude_line, 0 })
ui.detail_open()
assert(float_count() == 2, "detail float up before the list close")
ui.close()
assert(vim.wait(5000, function()
  return float_count() == 0
end, 20), "close() on the list also closed the detail float")
assert(not ui.is_open() and not ui.detail_is_open(), "both floats are gone")
assert(subs == unsubs, "close() released the list subscription: " .. subs .. "/" .. unsubs)

ui.open()
list_win = vim.api.nvim_get_current_win()
list_buf = vim.api.nvim_win_get_buf(list_win)
assert(vim.wait(5000, function()
  return text(list_buf):find("claude-1", 1, true) ~= nil
end, 20), "the reopened list rendered")
vim.api.nvim_win_set_cursor(list_win, { line_of(list_buf, "claude-1"), 0 })
ui.detail_open()
assert(float_count() == 2, "detail float up before the external list close")
vim.api.nvim_win_close(list_win, true)
assert(vim.wait(5000, function()
  return float_count() == 0
end, 20), "an external list close also closed the detail float")
assert(not ui.is_open() and not ui.detail_is_open(), "no orphaned float after an external close")
assert(subs == unsubs, "the external close released the subscription: " .. subs .. "/" .. unsubs)

-- 13. Error path: a failing binary must render an error line, not throw.
agents.stop()
local cached = agents.get()[1]
assert(cached and cached.target == "p1", "a cached agent to look up")
ui.open()
list_win = vim.api.nvim_get_current_win()
config.setup({
  cmd = "herdr-stub-fail",
  agents = { enabled = false, auto_start = false, poll_interval_ms = 100 },
})
assert(cli.available(), "herdr-stub-fail is on $PATH, so the failure is the CLI's exit code")
assert(pcall(ui.detail_open, cached), "detail_open() against a failing binary does not throw")
assert(ui.detail_is_open(), "the float still opens so the error has somewhere to land")
local err_buf = vim.api.nvim_win_get_buf(other_float(list_win))
assert(vim.wait(5000, function()
  return text(err_buf):find("error:", 1, true) ~= nil
end, 20), "the failed lookup renders an error line: " .. text(err_buf))
local err_body = text(err_buf)
assert(err_body:find("server", 1, true), "the error names the server: " .. err_body)
assert(not err_body:find("cwd:", 1, true), "the error replaces the field list")
assert(vim.bo[err_buf].modifiable == false, "the error frame is read-only too")
ui.detail_close()
assert(ui.is_open(), "the list survived the error path")

-- 14. Five open/close cycles leak neither buffers nor windows nor listeners.
config.setup({ cmd = "herdr-stub", agents = { enabled = false, auto_start = false } })
ui.render()
vim.api.nvim_win_set_cursor(list_win, { line_of(vim.api.nvim_win_get_buf(list_win), "claude-1"), 0 })
local bufs_before = #vim.api.nvim_list_bufs()
local subs_before = subs
for i = 1, 5 do
  ui.detail_open()
  assert(ui.detail_is_open(), "cycle " .. i .. ": detail float opened")
  assert(float_count() == 2, "cycle " .. i .. ": exactly two floats")
  ui.detail_close()
  assert(not ui.detail_is_open(), "cycle " .. i .. ": detail float closed")
  assert(float_count() == 1, "cycle " .. i .. ": back to the list alone")
end
-- Scheduled teardown from WinClosed/BufWipeout has to drain before counting.
vim.wait(200)
assert(
  #vim.api.nvim_list_bufs() == bufs_before,
  ("5 detail cycles leaked %d buffers"):format(#vim.api.nvim_list_bufs() - bufs_before)
)
assert(subs == subs_before, "the detail float never subscribes: " .. subs .. "/" .. subs_before)
assert(ui.is_open(), "the list is still open after 5 detail cycles")

-- 15. Teardown: no floats, no listeners, no timer.
ui.close()
agents.cleanup()
assert(float_count() == 0, "no float left at test end")
assert(not agents.is_polling(), "no polling left at test end")
assert(subs == unsubs, "no leaked agents.on_update subscription: " .. subs .. "/" .. unsubs)

agents.on_update = real_on_update
vim.notify = original_notify
print("PASS: F011 agent detail float opens on <CR>, closes independently, and tears down with the list")
