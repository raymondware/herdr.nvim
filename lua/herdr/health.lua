-- :checkhealth herdr - Neovim version, binary, version, server status,
-- config sanity. Every probe is synchronous (vim.system():wait()) with a
-- short timeout: checkhealth is a blocking report, not a place for async
-- callbacks, and the timeout keeps a wedged binary from freezing the check.
--
-- No JSON-mode probe: JSON is herdr's only agent-list format (see
-- docs/herdr-cli-facts.md), so there is nothing to detect.

local cli = require("herdr.cli")
local config = require("herdr.config")

local M = {}

local health = vim.health

-- Independent of agents.cli_timeout_ms: health probes should stay snappy
-- even if the user raised the polling timeout.
--
-- Kept deliberately small because :checkhealth is synchronous. The value is
-- passed to vim.system AND to :wait(), and SystemObj:wait() spends the budget
-- twice in the worst case (wait, SIGKILL, wait again for the pipes), so one
-- probe can block for 2x this. A responsive herdr answers in ~170ms.
local PROBE_TIMEOUT_MS = 800

-- Below this, polling spawns a herdr subprocess more than once a second,
-- which costs more than the freshness it buys.
local MIN_SANE_POLL_MS = 1000

-- config.options is {} until setup() runs; fall back to defaults so
-- :checkhealth herdr works pre-setup (matches the cli.lua convention).
local function cmd_name()
  return config.options.cmd or config.defaults.cmd
end

--- Run one herdr subcommand synchronously. nil (never a throw) on spawn
--- failure or timeout, so callers can degrade to a warn.
---@param args string[] subcommand arguments
---@return table|nil out vim.system result {code, stdout, stderr}
local function probe(args)
  local ok, out = pcall(function()
    return vim
      .system({ cmd_name(), unpack(args) }, { text = true, timeout = PROBE_TIMEOUT_MS })
      :wait(PROBE_TIMEOUT_MS)
  end)
  if not ok or type(out) ~= "table" then
    return nil
  end
  return out
end

-- 0.11, not 0.10: the plugin calls jobstart({ term = true }) (terminal.lua) and
-- the 4-argument vim.validate() (cli.lua, agents.lua), both introduced in 0.11
-- (news-0.11.txt: "jobstart() gained the 'term' flag", "vim.validate() now has
-- a new signature"). On 0.10 the term flag is silently ignored - :Herdr opens
-- an empty float - and vim.validate() raises, so green-lighting 0.10 would be
-- worse than no check at all.
local NVIM_MIN = "nvim-0.11"

local function check_nvim()
  if vim.fn.has(NVIM_MIN) == 1 then
    health.ok("Neovim >= 0.11")
  else
    health.error(
      "Neovim >= 0.11 required: jobstart({ term = true }) and the 4-argument"
        .. " vim.validate() are both 0.11 features",
      { "Upgrade Neovim to 0.11 or newer" }
    )
  end
end

---@return boolean found binary exists, boolean responsive it answered --version
local function check_binary()
  local cmd = cmd_name()
  if not cli.available() then
    health.error(("`%s` not found on $PATH"):format(cmd), {
      "Install herdr: https://herdr.dev",
      ("Or point at the binary: require('herdr').setup({ cmd = '/path/to/%s' })"):format(cmd),
    })
    return false, false
  end
  health.ok(("`%s` found on $PATH"):format(cmd))

  local out = probe({ "--version" })
  if out and out.code == 0 and out.stdout and vim.trim(out.stdout) ~= "" then
    health.ok(("version: %s"):format(vim.trim(out.stdout)))
  else
    health.warn("could not read `--version` output (timed out or empty)")
  end
  -- out == nil means the probe timed out or could not spawn. A binary that
  -- cannot answer --version will not answer `status` either, and skipping it
  -- halves the worst-case freeze.
  return true, out ~= nil
end

-- `herdr status` prints plain YAML-ish text and exits 0 with or without a
-- server, so a missing server is parsed from stdout, not from the exit code.
local function check_server()
  local out = probe({ "status" })
  if not out then
    health.warn("`status` probe did not run (timed out or failed to spawn)")
    return
  end
  if out.code ~= 0 then
    health.warn(
      ("`status` exited with code %d: %s"):format(out.code or -1, vim.trim(out.stderr or ""))
    )
    return
  end
  local stdout = out.stdout or ""
  -- Server down is a warn, not an error: attaching via :Herdr starts it.
  if stdout:find("status: not running", 1, true) then
    health.warn("herdr server not running - :Herdr will start it on attach")
  elseif stdout:find("status: running", 1, true) then
    health.ok("herdr server running")
  else
    health.warn("could not parse `status` output:\n" .. vim.trim(stdout))
  end
end

local function check_config()
  local keymaps = config.options.keymaps or config.defaults.keymaps
  if keymaps.toggle == "<C-r>" then
    health.info(
      "keymaps.toggle = <C-r> shadows redo in normal mode"
        .. " (deliberate default; set keymaps.toggle to another key or false to change)"
    )
  end

  local agents = config.options.agents or config.defaults.agents
  local interval = agents.poll_interval_ms
  if type(interval) == "number" and interval < MIN_SANE_POLL_MS then
    health.warn(
      ("agents.poll_interval_ms = %d spawns a herdr subprocess more than once a second"):format(
        interval
      ),
      { ("Raise it to %dms or higher"):format(MIN_SANE_POLL_MS) }
    )
  end
end

-- Contain section errors so one broken probe never aborts the whole report
-- (and headless pcall(M.check) stays true with the binary missing).
local function safely(fn)
  local ok, err = pcall(fn)
  if not ok then
    pcall(health.warn, ("health section failed: %s"):format(err))
  end
end

--- :checkhealth herdr entry point.
function M.check()
  health.start("herdr.nvim")
  safely(check_nvim)
  local found, responsive = false, false
  safely(function()
    found, responsive = check_binary()
  end)
  if found and responsive then
    safely(check_server)
  elseif found then
    health.warn("skipped the `status` probe: `--version` did not respond in time")
  end
  safely(check_config)
end

return M
