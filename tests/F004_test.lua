-- F004: terminal.lua floating modal terminal lifecycle
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F004_test.lua" -c "qa!"
-- cmd = "cat" gives a harmless long-lived job; cmd = "true" exits instantly
-- (close_on_exit path). Everything is killed at the end: a hang is a failure.

local config = require("herdr.config")
local term = require("herdr.terminal")

-- 1. open() creates an editor-relative float with configured geometry.
-- auto_insert is on by default: open() calls startinsert, which may be a
-- no-op headlessly; reaching the asserts proves it does not error.
config.setup({ cmd = "cat" })
term.open()
assert(term.is_open(), "open() opens the float")
assert(term.is_running(), "open() starts the job")

local win = vim.api.nvim_get_current_win()
local cfg = vim.api.nvim_win_get_config(win)
assert(cfg.relative == "editor", "float is editor-relative, got " .. tostring(cfg.relative))
assert(
  math.abs(cfg.width - math.floor(vim.o.columns * 0.85)) <= 1,
  ("width %d not ~85%% of %d columns"):format(cfg.width, vim.o.columns)
)
assert(
  math.abs(cfg.height - math.floor(vim.o.lines * 0.85)) <= 1,
  ("height %d not ~85%% of %d lines"):format(cfg.height, vim.o.lines)
)
assert(cfg.border ~= nil, "float has a border")

-- 2. The float hosts a real terminal buffer with a live job
local buf = vim.api.nvim_win_get_buf(win)
assert(vim.bo[buf].buftype == "terminal", "buffer is a terminal, got " .. vim.bo[buf].buftype)
local job = vim.b[buf].terminal_job_id
assert(type(job) == "number" and job > 0, "terminal_job_id set")

-- 3. Buffer-local t-mode maps: toggle key present, <Esc> deliberately absent
-- (herdr TUI needs raw Escape)
local found_toggle, found_esc = false, false
for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "t")) do
  local lhs = vim.keycode(m.lhs)
  if lhs == vim.keycode("<C-r>") then
    found_toggle = true
  end
  if lhs == vim.keycode("<Esc>") then
    found_esc = true
  end
end
assert(found_toggle, "buffer-local t-mode toggle mapping exists (toggle_in_terminal=true)")
assert(not found_esc, "no <Esc> mapping in the terminal buffer")

-- 4. hide() closes the window; buffer and job survive (persist_buffer=true)
term.hide()
assert(not term.is_open(), "hide() closes the float")
assert(vim.api.nvim_buf_is_valid(buf), "buffer survives hide()")
assert(vim.fn.jobwait({ job }, 0)[1] == -1, "job still running after hide()")
assert(term.is_running(), "is_running() true while hidden")

-- 5. toggle() reopens the SAME buffer (scrollback preserved)
term.toggle()
assert(term.is_open(), "toggle() reopens the float")
assert(
  vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == buf,
  "toggle() reuses the same bufnr"
)

-- 6. VimResized recomputes geometry while the float is open
local old_columns = vim.o.columns
vim.o.columns = old_columns + 40
vim.api.nvim_exec_autocmds("VimResized", {})
local resized = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
assert(
  math.abs(resized.width - math.floor(vim.o.columns * 0.85)) <= 1,
  ("width %d did not track resize to %d columns"):format(resized.width, vim.o.columns)
)
vim.o.columns = old_columns
vim.api.nvim_exec_autocmds("VimResized", {})

-- 7. toggle() while open hides (persist_buffer=true default), not kills
term.toggle()
assert(not term.is_open(), "toggle() hides when open")
assert(vim.api.nvim_buf_is_valid(buf), "persist_buffer=true keeps the buffer on toggle-off")

-- UPSTREAM WORKAROUND (not a plugin fix): headless nvim 0.12.4 aborts with
-- "Caught deadly signal 'SIGHUP'" when PTYs are torn down and recreated inside
-- the same event-loop turn. qa-reports/F004.md includes a plugin-free repro
-- (float + jobstart{term=true} + jobstop + win_close + buf_delete in a tight
-- loop) that crashes at the same rate, so this is nvim/libuv behavior in
-- headless mode; a real UI is unaffected. settle() gives libuv a turn to reap
-- the PTY before the next open(), which keeps this test out of that window.
local function settle()
  vim.wait(120)
end

-- 8. kill() wipes the buffer and stops the job
term.kill()
vim.wait(2000, function()
  return not vim.api.nvim_buf_is_valid(buf)
end)
assert(not vim.api.nvim_buf_is_valid(buf), "kill() wipes the buffer")
assert(not term.is_open(), "kill() leaves nothing open")
assert(not term.is_running(), "kill() stops the job")
assert(vim.fn.jobwait({ job }, 2000)[1] ~= -1, "job is dead after kill()")
settle()

-- 9. persist_buffer=false: toggle-off kills instead of hiding
config.setup({ cmd = "cat", terminal = { persist_buffer = false } })
term.open()
assert(term.is_open(), "open() works with persist_buffer=false")
local buf2 = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
local job2 = vim.b[buf2].terminal_job_id
term.toggle()
assert(not term.is_open(), "toggle-off closes the float")
vim.wait(2000, function()
  return not vim.api.nvim_buf_is_valid(buf2)
end)
assert(not vim.api.nvim_buf_is_valid(buf2), "persist_buffer=false wipes the buffer on toggle-off")
assert(vim.fn.jobwait({ job2 }, 2000)[1] ~= -1, "persist_buffer=false kills the job on toggle-off")
settle()

-- 10. close_on_exit: job exiting on its own closes the float and wipes the
-- buffer (covers `herdr quit` and ctrl+b q detach)
config.setup({ cmd = "true" })
term.open()
assert(term.is_open(), "open() works with instantly-exiting cmd")
local buf3 = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
assert(vim.wait(2000, function()
  return not term.is_open()
end), "close_on_exit closes the float when the job exits")
vim.wait(2000, function()
  return not vim.api.nvim_buf_is_valid(buf3)
end)
assert(not vim.api.nvim_buf_is_valid(buf3), "close_on_exit wipes the buffer")
assert(not term.is_running(), "no job after self-exit")
settle()

-- 11. Missing binary: single notify mentioning 'not found' and
-- ':checkhealth herdr'; no window or buffer created
config.setup({ cmd = "no-such-bin-xyz" })
local notifications = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  notifications[#notifications + 1] = { msg = msg, level = level }
end
local bufs_before = #vim.api.nvim_list_bufs()
local wins_before = #vim.api.nvim_list_wins()
term.open()
vim.notify = orig_notify
assert(#notifications == 1, "exactly one notification, got " .. #notifications)
assert(notifications[1].msg:find("not found", 1, true), "notify mentions 'not found'")
assert(notifications[1].msg:find(":checkhealth herdr", 1, true), "notify points to :checkhealth herdr")
assert(notifications[1].level == vim.log.levels.ERROR, "notify level is ERROR")
assert(not term.is_open(), "no window created for missing binary")
assert(not term.is_running(), "no job started for missing binary")
assert(#vim.api.nvim_list_bufs() == bufs_before, "no buffer created for missing binary")
assert(#vim.api.nvim_list_wins() == wins_before, "no window leaked for missing binary")

-- 12. Cleanup: kill everything so headless nvim exits cleanly
config.setup({ cmd = "cat" })
term.open()
assert(term.is_open() and term.is_running(), "terminal usable again after all paths")
term.kill()
assert(not term.is_open() and not term.is_running(), "final kill() leaves nothing behind")
-- Same upstream workaround: let the last PTY be reaped before nvim exits.
settle()

print("PASS: F004 floating modal terminal lifecycle")
