-- Public facade: setup(), user commands, keymaps, Herdr augroup.
-- Delegation only - the terminal and (later) agents modules own the logic.
--
-- The agents / agents_ui modules land in later features (F007/F009). Every
-- reference to them here is behind pcall (and, for VimLeavePre cleanup, a
-- package.loaded check) so this facade works today and picks the modules up
-- automatically once they exist, without force-loading anything.

local cli = require("herdr.cli")
local config = require("herdr.config")
local terminal = require("herdr.terminal")

local M = {}

local setup_done = false

-- Keymaps THIS plugin created, so a later setup() can take back the ones it no
-- longer wants: {mode, lhs, desc}. Nothing else may be deleted.
local applied_keymaps = {}

--- Guard for public entry points: everything assumes config.setup() ran.
---@return boolean ok
local function ensure_setup()
  if setup_done then
    return true
  end
  vim.notify(
    'Call require("herdr").setup({}) first',
    vim.log.levels.WARN,
    { title = "herdr" }
  )
  return false
end

local POLL_ACTIONS = { "start", "stop", "toggle" }

--- Toggle the floating herdr terminal.
function M.toggle()
  if not ensure_setup() then
    return
  end
  terminal.toggle()
end

--- Open (or focus) the floating herdr terminal.
function M.open()
  if not ensure_setup() then
    return
  end
  terminal.open()
end

--- Hide the floating terminal; buffer + job persist by default.
function M.close()
  if not ensure_setup() then
    return
  end
  terminal.hide()
end

--- Kill the herdr client job and wipe the terminal buffer.
function M.kill()
  if not ensure_setup() then
    return
  end
  terminal.kill()
end

--- Toggle the agent status float (F009; notifies until it exists).
function M.agents()
  if not ensure_setup() then
    return
  end
  local ok, ui = pcall(require, "herdr.agents_ui")
  if ok then
    ui.toggle()
  else
    vim.notify("herdr: agent UI not yet available", vim.log.levels.WARN, { title = "herdr" })
  end
end

--- Control agent polling (F007; notifies until it exists).
---@param action string|nil "start" | "stop" | "toggle" (default "toggle")
function M.poll(action)
  if not ensure_setup() then
    return
  end
  action = action or "toggle"
  if not vim.tbl_contains(POLL_ACTIONS, action) then
    vim.notify(
      ("herdr: invalid poll action %q (start|stop|toggle)"):format(action),
      vim.log.levels.WARN,
      { title = "herdr" }
    )
    return
  end
  local ok, agents = pcall(require, "herdr.agents")
  if not ok then
    vim.notify("herdr: agent polling not yet available", vim.log.levels.WARN, { title = "herdr" })
    return
  end
  if action == "start" then
    agents.start()
  elseif action == "stop" then
    agents.stop()
  elseif agents.is_polling() then
    agents.stop()
  else
    agents.start()
  end
end

--- Status snapshot. Safe pre-setup (pure queries) and while herdr.agents
--- does not exist yet: the agents subtable stays at its inert placeholder.
---@return table {available, cmd, terminal = {open, running}, agents = {polling, counts, degraded, last_error}}
function M.status()
  local status = {
    available = cli.available(),
    cmd = config.options.cmd or config.defaults.cmd,
    terminal = {
      open = terminal.is_open(),
      running = terminal.is_running(),
    },
    agents = {
      polling = false,
      counts = nil,
      degraded = false,
      last_error = nil,
    },
  }
  local ok, agents = pcall(require, "herdr.agents")
  if ok then
    status.agents.polling = agents.is_polling()
    status.agents.counts = agents.counts()
    status.agents.degraded = agents.is_degraded()
    status.agents.last_error = agents.last_error()
  end
  return status
end

--- One-line :HerdrStatus summary via vim.notify.
local function notify_status()
  local s = M.status()
  vim.notify(
    ("herdr: cli %s | terminal %s%s | polling %s%s"):format(
      s.available and "available" or "missing",
      s.terminal.open and "open" or "closed",
      s.terminal.running and " (running)" or "",
      s.agents.polling and "on" or "off",
      s.agents.degraded and " (degraded)" or ""
    ),
    vim.log.levels.INFO,
    { title = "herdr" }
  )
end

-- The full set of mappings setup() owns. desc doubles as the fingerprint that
-- proves a mapping is still ours before we delete it.
local KEYMAP_SPECS = {
  {
    option = "toggle",
    desc = "herdr: toggle terminal",
    rhs = function()
      M.toggle()
    end,
  },
  {
    option = "agents",
    desc = "herdr: agent status",
    rhs = function()
      M.agents()
    end,
  },
}

--- Whether the mapping currently at (mode, lhs) is the one we created.
--- Guards against clobbering a user remap that landed on the same lhs after
--- our setup(): if the desc no longer matches, the mapping is not ours.
---@return boolean
local function is_plugin_mapping(mode, lhs, desc)
  local map = vim.fn.maparg(lhs, mode, false, true)
  if type(map) ~= "table" or vim.tbl_isempty(map) then
    return false
  end
  return map.desc == desc
end

--- Re-apply the configured keymaps, first removing plugin mappings that the
--- new config no longer asks for (unset, or the same action retargeted to a
--- different lhs). Without this, `setup({keymaps = {toggle = false}})` after a
--- default setup() left <C-r> shadowing redo forever.
local function apply_keymaps()
  local keymaps = config.options.keymaps or config.defaults.keymaps

  local wanted = {}
  for _, spec in ipairs(KEYMAP_SPECS) do
    local lhs = keymaps[spec.option]
    -- Explicit false (or nil) skips the mapping so a lazy `keys` spec can own
    -- it instead.
    if type(lhs) == "string" and lhs ~= "" then
      wanted[#wanted + 1] = { mode = "n", lhs = lhs, desc = spec.desc, rhs = spec.rhs }
    end
  end

  for _, old in ipairs(applied_keymaps) do
    local keep = false
    for _, new in ipairs(wanted) do
      if new.mode == old.mode and new.lhs == old.lhs then
        keep = true
        break
      end
    end
    if not keep and is_plugin_mapping(old.mode, old.lhs, old.desc) then
      pcall(vim.keymap.del, old.mode, old.lhs)
    end
  end

  applied_keymaps = {}
  for _, new in ipairs(wanted) do
    vim.keymap.set(new.mode, new.lhs, new.rhs, { desc = new.desc, silent = true })
    applied_keymaps[#applied_keymaps + 1] = {
      mode = new.mode,
      lhs = new.lhs,
      desc = new.desc,
    }
  end
end

function M.setup(opts)
  config.setup(opts)

  -- Documented setup order (architecture.json): config.setup -> hl.setup ->
  -- augroup -> commands -> keymaps -> agents.start. hl.setup() is idempotent,
  -- so calling it here is additive even though agents_ui.lua also has a lazy
  -- one-shot fallback.
  pcall(function()
    require("herdr.hl").setup()
  end)

  -- The plugin/ reminder command has served its purpose once setup() runs.
  pcall(vim.api.nvim_del_user_command, "HerdrSetup")

  local commands = {
    { "Herdr", function() M.toggle() end,
      { desc = "Toggle the floating herdr terminal" } },

    { "HerdrOpen", function() M.open() end,
      { desc = "Open (or focus) the floating herdr terminal" } },

    { "HerdrClose", function() M.close() end,
      { desc = "Hide the floating terminal (buffer + job persist by default)" } },

    { "HerdrKill", function() M.kill() end,
      { desc = "Kill the herdr client job and wipe the terminal buffer" } },

    { "HerdrAgents", function() M.agents() end,
      { desc = "Toggle the agent status float" } },

    { "HerdrStatus", notify_status,
      { desc = "Print terminal/polling status summary" } },

    { "HerdrPoll", function(cmd)
      M.poll(cmd.args ~= "" and cmd.args or nil)
    end, {
      nargs = "?",
      -- Nvim does not filter what a Lua complete function returns, so match
      -- ArgLead here or `:HerdrPoll st<Tab>` offers "toggle" too.
      complete = function(arg_lead)
        if not arg_lead or arg_lead == "" then
          return POLL_ACTIONS
        end
        return vim.tbl_filter(function(action)
          return action:find(arg_lead, 1, true) == 1
        end, POLL_ACTIONS)
      end,
      desc = "Control agent polling: start|stop|toggle (default toggle)",
    } },
  }

  for _, cmd in ipairs(commands) do
    -- Delete-then-create keeps repeated setup() calls idempotent (no E174).
    pcall(vim.api.nvim_del_user_command, cmd[1])
    vim.api.nvim_create_user_command(cmd[1], cmd[2], cmd[3])
  end

  apply_keymaps()

  local augroup = vim.api.nvim_create_augroup("Herdr", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    desc = "herdr: stop the agent poll timer so nvim can exit",
    callback = function()
      -- Only clean up a module that actually loaded; require()ing at exit
      -- would be pointless (nothing to stop) and the package.loaded check
      -- keeps this a no-op until F007 ships herdr.agents.
      if package.loaded["herdr.agents"] then
        pcall(function()
          require("herdr.agents").cleanup()
        end)
      end
    end,
  })

  setup_done = true

  local agents_opts = config.options.agents
  if agents_opts.enabled and agents_opts.auto_start then
    -- pcall tolerates the module missing until F007 makes polling real.
    pcall(function()
      require("herdr.agents").start()
    end)
  end
end

return M
