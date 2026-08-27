-- Floating modal terminal hosting the herdr TUI client.
--
-- ORDER IS LOAD-BEARING (nvim 0.12; termopen() is deprecated):
--   1) scratch buffer, 2) nvim_open_win float, 3) jobstart{term=true} inside
--   nvim_buf_call. jobstart{term=true} requires an empty current buffer and
--   sizes the PTY from the CURRENT WINDOW, so the float must exist first.
--
-- Toggle-off only hides the window: the buffer and client job survive so
-- scrollback is preserved and reopening is instant (the herdr server persists
-- regardless). terminal.persist_buffer=false opts into kill-on-toggle;
-- M.kill() / :HerdrKill is the explicit teardown.

local cli = require("herdr.cli")
local config = require("herdr.config")

local M = {}

-- Single generation of terminal state. job is tracked separately from
-- vim.b.terminal_job_id so exit callbacks from a dead generation (after
-- kill() or a fast kill->open) can be told apart from the live one.
local state = {
  buf = nil, ---@type integer|nil
  win = nil, ---@type integer|nil
  job = nil, ---@type integer|nil
}

-- config.options is {} until setup() runs; fall back to defaults so the
-- module never indexes nil (matches the cli.lua convention).
local function opt(key)
  return config.options[key] or config.defaults[key]
end

-- Fractions (<= 1) scale against the editor dimension; larger values are
-- absolute cell counts.
local function scale(value, total)
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
end

--- Compute the float config from current editor size; called on every open
--- and again from the VimResized autocmd so the float tracks resizes.
---@return table win_config for nvim_open_win / nvim_win_set_config
local function win_config()
  local window = opt("window")
  local has_border = window.border ~= nil and window.border ~= "none"
  -- A border draws one extra cell on every side; shrink the usable area so
  -- the frame stays on screen, and shift the centering by the same amount.
  local pad = has_border and 2 or 0
  local width = math.max(1, math.min(scale(window.width, vim.o.columns), vim.o.columns - pad))
  local height = math.max(1, math.min(scale(window.height, vim.o.lines), vim.o.lines - pad - 1))
  local cfg = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height - pad) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - pad) / 2)),
    style = "minimal",
    border = window.border,
  }
  if has_border and window.title then
    -- 'title' is only valid together with a border
    cfg.title = window.title
    cfg.title_pos = "center"
  end
  return cfg
end

---@return string[] argv for jobstart
local function build_cmd()
  local options = config.options
  local cmd = { options.cmd or config.defaults.cmd }
  if options.session then
    cmd[#cmd + 1] = "--session"
    cmd[#cmd + 1] = options.session
  end
  return vim.list_extend(cmd, options.extra_args or {})
end

---@return boolean
function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

---@return boolean
function M.is_running()
  return state.job ~= nil and vim.fn.jobwait({ state.job }, 0)[1] == -1
end

--- Job exit handler (always vim.schedule_wrap'd; terminal callbacks run in
--- a fast-event context). Covers both `herdr quit` and ctrl+b q detach.
---@param job_id integer the job that exited
local function handle_exit(job_id)
  if job_id ~= state.job then
    -- Exit from a dead generation: kill() already tore it down, or open()
    -- has since started a fresh job. Touch nothing.
    return
  end
  state.job = nil
  if not opt("terminal").close_on_exit then
    return
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.buf = nil
end

local augroup = vim.api.nvim_create_augroup("HerdrTerminal", { clear = true })

--- Enter insert mode in the herdr float, but only if the float is still the
--- current window when it actually happens.
---
--- WHY the schedule + re-check: `:startinsert` does not take effect inside a
--- script, it sets a pending flag that fires when control returns to the main
--- loop. So `open()` immediately followed by `hide()`/`kill()` in the same tick
--- used to land that pending insert in whatever buffer the cursor fell back to
--- (the user's own file), turning their next keystrokes into text.
local function enter_insert()
  if not opt("terminal").auto_insert then
    return
  end
  vim.schedule(function()
    if M.is_open() and vim.api.nvim_get_current_win() == state.win then
      pcall(vim.cmd.startinsert)
    end
  end)
end

--- Teardown counterpart: cancel a pending (or active) insert so closing the
--- float always leaves the user in Normal mode. Only when the float was the
--- current window - otherwise the user's own insert session is none of our
--- business.
---@param was_current boolean
local function leave_insert(was_current)
  if was_current then
    pcall(vim.cmd.stopinsert)
  end
end

--- Whether the herdr float is the window the cursor is in right now.
---@return boolean
local function is_current()
  return M.is_open() and vim.api.nvim_get_current_win() == state.win
end

-- One-time, buffer-scoped wiring; dies with the buffer so nothing leaks.
local function attach_buffer(buf)
  -- Re-enter insert whenever the user comes back to the terminal, so the
  -- TUI is immediately interactive (checked at event time to honor setup()
  -- changes between opens).
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = buf,
    callback = enter_insert,
  })

  -- Deliberately NO <Esc> terminal mapping: the herdr TUI needs raw Escape.
  -- <C-\><C-n> remains the way out of terminal-mode (documented in README).
  local keymaps = opt("keymaps")
  if keymaps.toggle_in_terminal and type(keymaps.toggle) == "string" then
    vim.keymap.set("t", keymaps.toggle, M.toggle, {
      buffer = buf,
      desc = "herdr: toggle terminal",
    })
  end
end

--- Open the float, starting the herdr client job if one is not running.
--- Reuses the persisted buffer (scrollback intact) when its job is alive.
function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  if not cli.available() then
    vim.notify(
      ("herdr: `%s` not found on $PATH (run :checkhealth herdr)"):format(
        config.options.cmd or config.defaults.cmd
      ),
      vim.log.levels.ERROR
    )
    return
  end

  local reuse = state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf) and M.is_running()
  if not reuse then
    -- A stale buffer (job exited with close_on_exit=false) cannot host a
    -- new job: jobstart{term=true} needs an empty buffer. Start fresh.
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_delete(state.buf, { force = true })
    end
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].bufhidden = "hide"
    attach_buffer(state.buf)
  end

  state.win = vim.api.nvim_open_win(state.buf, true, win_config())

  if not reuse then
    vim.api.nvim_buf_call(state.buf, function()
      state.job = vim.fn.jobstart(build_cmd(), {
        term = true,
        on_exit = vim.schedule_wrap(handle_exit),
      })
    end)
    if not state.job or state.job <= 0 then
      state.job = nil
      M.kill()
      vim.notify("herdr: failed to start client job", vim.log.levels.ERROR)
      return
    end
  end

  enter_insert()
end

--- Close the float only; buffer and job survive for the next open().
function M.hide()
  local was_current = is_current()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  leave_insert(was_current)
end

--- Full teardown: stop the client job, close the float, wipe the buffer.
function M.kill()
  local was_current = is_current()
  local job = state.job
  -- Cleared BEFORE jobstop so the scheduled handle_exit sees a dead
  -- generation and does not double-teardown (or tear down a fast reopen).
  state.job = nil
  if job then
    pcall(vim.fn.jobstop, job)
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.buf = nil
  leave_insert(was_current)
end

--- One key opens and dismisses the float. Toggle-off hides (default) or
--- kills when terminal.persist_buffer is false.
function M.toggle()
  if M.is_open() then
    if opt("terminal").persist_buffer then
      M.hide()
    else
      M.kill()
    end
  else
    M.open()
  end
end

-- Keep the float centered and sized when the editor is resized.
vim.api.nvim_create_autocmd("VimResized", {
  group = augroup,
  callback = function()
    if M.is_open() then
      vim.api.nvim_win_set_config(state.win, win_config())
    end
  end,
})

return M
