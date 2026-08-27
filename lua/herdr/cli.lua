-- All herdr subprocess calls (vim.system) plus pure JSON envelope parsers.
-- Ground truth for formats: docs/herdr-cli-facts.md (herdr 0.7.5, verified
-- live). `herdr agent list` / `agent get` are JSON-native; there is no --json
-- flag and no plain-text format, so there is exactly one parser per envelope.

local config = require("herdr.config")

local M = {}

-- agent_status enum from the herdr API schema. Anything the server sends
-- outside this set is clamped to "unknown" so downstream UI code never has
-- to defend against enum drift between herdr versions.
local KNOWN_STATES = {
  idle = true,
  working = true,
  blocked = true,
  done = true,
  unknown = true,
}

-- config.options is {} until setup() runs; fall back to defaults so cli
-- helpers are safe to call (e.g. from :checkhealth) before setup.
local function cmd_name()
  return config.options.cmd or config.defaults.cmd
end

--- Coerced, not trusted: config.setup() validates nothing, and a stringly-typed
--- or non-finite timeout reaching vim.system throws from a frame whose callback
--- would then never run (see the INVARIANT note near the bottom of this file).
---@return integer
local function cli_timeout_ms()
  local agents = config.options.agents or config.defaults.agents
  local value = tonumber(agents.cli_timeout_ms)
  -- Anything unusable falls back to the default rather than being clamped:
  -- 0 or negative would kill every child before it could answer, and NaN/inf
  -- survive tonumber but not vim.system. A value that cannot be honored is not
  -- a choice the user made, so the plugin uses its own.
  if
    value == nil
    or value ~= value
    or value == math.huge
    or value == -math.huge
    or value < 1
  then
    value = config.defaults.agents.cli_timeout_ms
  end
  return math.floor(value)
end

--- The configured herdr session name, or nil when unset or blank.
---
--- Exported because agents.lua needs the effective request identity (cmd +
--- session) to recognize a response produced by a superseded config.
---@return string|nil
function M.session()
  local session = config.options.session
  if session == nil then
    session = config.defaults.session
  end
  if type(session) ~= "string" or vim.trim(session) == "" then
    return nil
  end
  return session
end

--- Identity of the herdr server a request is spawned against.
---
--- cmd + session is the whole identity: they are the only config values that
--- decide WHICH server answers. Exported so every caller that has to recognize a
--- response produced by a config the user has since moved away from
--- (agents.lua's poll, agents_ui.lua's workspace lookup) compares against ONE
--- definition of that identity instead of keeping its own copy.
---@return string
function M.spawn_key()
  return ("%s\0%s"):format(cmd_name(), M.session() or "")
end

--- Full argv for one herdr invocation.
---
--- `--session <name>` is a GLOBAL flag that herdr 0.7.5 accepts either before or
--- after the subcommand - both forms were verified live against a named session
--- and route to `~/.config/herdr/sessions/<name>/herdr.sock` (see
--- docs/herdr-cli-facts.md). It is APPENDED so positional subcommand arguments
--- keep their argv indices, which is what the test stubs parse. Without it every
--- poll targets the default socket while the TUI targets the named one, so a
--- user with `session = "work"` would watch a server they are not using.
---@param args string[] subcommand arguments
---@return string[]
local function argv(args)
  local out = { cmd_name() }
  vim.list_extend(out, args)
  local session = M.session()
  if session then
    out[#out + 1] = "--session"
    out[#out + 1] = session
  end
  return out
end

--- Whether the configured herdr binary is on $PATH (or an executable path).
---@return boolean
function M.available()
  return vim.fn.executable(cmd_name()) == 1
end

--- PURE: normalize one raw AgentInfo into the plugin-facing shape.
--- target is pane_id because that is what `herdr agent get/focus <target>`
--- address; name walks the nullable-field fallback chain so every agent has
--- a displayable label; detail keeps the raw AgentInfo for the detail float.
---
--- Returns nil for anything that is not a table. WHY skip rather than
--- synthesize an "unknown" placeholder: every downstream consumer addresses an
--- agent by `target` (pane_id), and a scalar array entry carries no pane_id, so
--- a placeholder would render an un-addressable row in the F009 list and make
--- `agent get`/`focus` fail on it. A missing row is strictly better than a
--- broken one, and the entry was not a valid AgentInfo to begin with.
---@param info table raw AgentInfo from a herdr envelope
---@return table|nil agent {target, name, state, kind, detail, focused, pane_id}
function M.normalize_agent(info)
  if type(info) ~= "table" then
    return nil
  end
  local state = info.agent_status
  if not KNOWN_STATES[state] then
    state = "unknown"
  end
  return {
    target = info.pane_id,
    name = info.name or info.display_agent or info.agent or info.title or info.pane_id,
    state = state,
    kind = info.agent,
    detail = info,
    focused = info.focused,
    pane_id = info.pane_id,
  }
end

--- PURE: normalize one raw WorkspaceInfo into the plugin-facing shape.
---
--- `state` is the workspace's rolled-up `agent_status`, clamped to the documented
--- enum exactly like an agent's, so the grouped view can colorize a workspace
--- header with the same STATE_HL table it uses for a row.
---
--- Returns nil for anything that is not a table, and for a table with no usable
--- `workspace_id`. WHY skip rather than keep it: the only thing a workspace
--- record is FOR here is answering "what is workspace <id> called", so an entry
--- that cannot be keyed by id is unusable, and a placeholder would collide with
--- every other unkeyable entry. Same reasoning as normalize_agent skipping an
--- entry with no pane to address.
---@param info table raw WorkspaceInfo from a herdr envelope
---@return table|nil workspace {workspace_id, label, number, focused, state, tab_count, pane_count}
function M.normalize_workspace(info)
  if type(info) ~= "table" then
    return nil
  end
  local id = info.workspace_id
  if type(id) ~= "string" or id == "" then
    return nil
  end
  local state = info.agent_status
  if not KNOWN_STATES[state] then
    state = "unknown"
  end
  return {
    workspace_id = id,
    -- Labels are NOT unique (herdr happily labels several workspaces the same),
    -- so this is a display hint only; the id stays the identity.
    label = type(info.label) == "string" and info.label or nil,
    number = tonumber(info.number),
    focused = info.focused,
    state = state,
    tab_count = tonumber(info.tab_count),
    pane_count = tonumber(info.pane_count),
  }
end

-- vim.system reports a timed-out child as exit code 124 after signalling it
-- (see :help vim.system); a real herdr exit never carries a signal.
local TIMEOUT_CODE = 124

-- Anything can arrive here in principle (this is the error path, so it must be
-- the most defensive code in the file): coerce to a trimmed string.
local function as_text(value)
  if value == nil then
    return ""
  end
  if type(value) == "string" then
    return vim.trim(value)
  end
  return vim.trim(tostring(value))
end

-- herdr 0.7.5 reports API-level failures as a JSON envelope on stderr, e.g.
-- {"error":{"code":"agent_not_found","message":"agent target x not found"},
--  "id":"cli:agent:get"} - see docs/herdr-cli-facts.md. Users get the human
-- message, never the raw envelope.
---@param text string
---@return string|nil
local function envelope_message(text)
  if not text:find('"error"', 1, true) then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, text, {
    luanil = { object = true, array = true },
  })
  if not ok or type(decoded) ~= "table" or type(decoded.error) ~= "table" then
    return nil
  end
  local message = decoded.error.message
  if type(message) ~= "string" or vim.trim(message) == "" then
    return nil
  end
  return vim.trim(message)
end

--- PURE: map a failed vim.system result to a user-facing error string.
--- Exit 1 with the `Error: Os {...}` stderr signature is how herdr reports
--- a missing server socket, which deserves an actionable message instead of
--- raw Rust debug output. Never throws, for any input.
---@param out table vim.system result {code, signal, stderr, stdout}
---@param timeout_ms integer|nil timeout the call was made with (for the message)
---@return string
function M.normalize_error(out, timeout_ms)
  out = type(out) == "table" and out or {}
  local stderr = as_text(out.stderr)
  local stdout = as_text(out.stdout)

  if stderr:find("Error: Os {", 1, true) then
    return "herdr server not running (start with `herdr` or `herdr server`)"
  end

  local message = envelope_message(stderr) or envelope_message(stdout)
  if message then
    return ("herdr: %s"):format(message)
  end

  local code = tonumber(out.code) or -1
  local signal = tonumber(out.signal) or 0
  if code == TIMEOUT_CODE and signal ~= 0 then
    return ("herdr command timed out after %dms"):format(
      tonumber(timeout_ms) or cli_timeout_ms()
    )
  end

  if stderr == "" then
    return ("herdr exited with code %d"):format(code)
  end
  return ("herdr exited with code %d: %s"):format(code, stderr)
end

-- Shared envelope decode: pcall'd vim.json.decode with luanil so JSON nulls
-- become real nils (the name fallback chain relies on that), then a shape
-- check on result.<key>.
local function decode_result(stdout, key, expected_type)
  local ok, decoded = pcall(vim.json.decode, stdout or "", {
    luanil = { object = true, array = true },
  })
  if not ok or type(decoded) ~= "table" then
    return nil, "herdr returned invalid JSON"
  end
  local result = decoded.result
  if type(result) ~= "table" or type(result[key]) ~= expected_type then
    return nil, ("unexpected herdr envelope: missing result.%s"):format(key)
  end
  return result[key]
end

--- PURE: parse a `herdr agent list` envelope into normalized agents.
---@param stdout string raw stdout
---@return table[]|nil agents, string|nil err
function M.parse_agent_list(stdout)
  local raw, err = decode_result(stdout, "agents", "table")
  if not raw then
    return nil, err
  end
  -- `agents` is an array in the schema. A JSON object here would pass the
  -- type check and then produce a silent empty-but-successful list, which
  -- reads as "no agents" instead of "herdr said something unexpected".
  -- vim.islist({}) is true, so a genuinely empty list still works.
  if not vim.islist(raw) then
    return nil, "unexpected herdr envelope: result.agents is not an array"
  end
  local agents = {}
  for _, info in ipairs(raw) do
    -- Skip non-object entries (see normalize_agent) instead of throwing: this
    -- parser runs inside a vim.system callback, where a throw used to swallow
    -- the caller's callback entirely.
    local agent = M.normalize_agent(info)
    if agent then
      agents[#agents + 1] = agent
    end
  end
  return agents
end

--- PURE: parse a `herdr workspace list` envelope into normalized workspaces.
--- Same defensive discipline as parse_agent_list: pcall'd decode, an object where
--- an array belongs is an error rather than a silent empty list, and unusable
--- entries are skipped instead of throwing (this runs inside a vim.system
--- callback, where a throw loses the caller's callback entirely).
---@param stdout string raw stdout
---@return table[]|nil workspaces, string|nil err
function M.parse_workspace_list(stdout)
  local raw, err = decode_result(stdout, "workspaces", "table")
  if not raw then
    return nil, err
  end
  if not vim.islist(raw) then
    return nil, "unexpected herdr envelope: result.workspaces is not an array"
  end
  local workspaces = {}
  for _, info in ipairs(raw) do
    local workspace = M.normalize_workspace(info)
    if workspace then
      workspaces[#workspaces + 1] = workspace
    end
  end
  return workspaces
end

--- PURE: parse a `herdr agent get <target>` envelope into one agent.
---@param stdout string raw stdout
---@return table|nil agent, string|nil err
function M.parse_agent_get(stdout)
  local raw, err = decode_result(stdout, "agent", "table")
  if not raw then
    return nil, err
  end
  -- `agent` is a single object. A populated JSON array would pass the type
  -- check and normalize into an all-nil agent; `{}` stays allowed because an
  -- empty table is an empty object and an empty array at the same time.
  if vim.islist(raw) and next(raw) ~= nil then
    return nil, "unexpected herdr envelope: result.agent is not an object"
  end
  local agent = M.normalize_agent(raw)
  if not agent then
    return nil, "unexpected herdr envelope: result.agent is not an object"
  end
  return agent
end

--- Run the herdr binary asynchronously. cb receives the vim.system result
--- object on the main loop, or (nil, err) when the binary is missing or
--- spawning fails; it never throws.
---@param args string[] subcommand arguments
---@param cb fun(out: table|nil, err: string|nil)
---@param opts table|nil {timeout_ms}
function M.run(args, cb, opts)
  vim.validate("args", args, "table")
  vim.validate("cb", cb, "callable")
  vim.validate("opts", opts, "table", true)
  opts = opts or {}

  if not M.available() then
    -- Scheduled (not called inline) so cb is always async, matching the
    -- success path; callers never re-enter their own frame.
    vim.schedule(function()
      cb(nil, ("herdr binary not found: %s"):format(cmd_name()))
    end)
    return
  end

  local sys_ok, sys_err = pcall(vim.system, argv(args), {
    text = true,
    timeout = opts.timeout_ms or cli_timeout_ms(),
  }, vim.schedule_wrap(cb))
  if not sys_ok then
    vim.schedule(function()
      cb(nil, ("failed to spawn herdr: %s"):format(sys_err))
    end)
  end
end

-- INVARIANT: for ANY subprocess output whatsoever, cb is invoked exactly once.
--
-- The two helpers below are what make that true. Both run inside the
-- vim.system callback, where an uncaught error does not propagate to the
-- caller - it is reported by the scheduler and the callback is simply lost.
-- A lost callback is the one failure agents.lua cannot survive: its in_flight
-- guard would never be released and polling would wedge forever, silently.

---@param out table|nil vim.system result
---@param timeout_ms integer effective timeout of the call
---@return string
local function safe_error(out, timeout_ms)
  local ok, message = pcall(M.normalize_error, out, timeout_ms)
  if ok and type(message) == "string" then
    return message
  end
  return "herdr failed (error could not be described)"
end

--- Run `parser(...)` under pcall and hand the outcome to cb exactly once.
---@param cb fun(result: any, err: string|nil)
---@param parser fun(...): any, string|nil
local function deliver(cb, parser, ...)
  local ok, result, err = pcall(parser, ...)
  if not ok then
    return cb(nil, ("herdr response could not be parsed: %s"):format(tostring(result)))
  end
  if result == nil and err == nil then
    return cb(nil, "herdr returned no usable result")
  end
  return cb(result, err)
end

--- Async `herdr agent list`; cb(agents|nil, err|nil).
---@param cb fun(agents: table[]|nil, err: string|nil)
function M.agent_list(cb)
  local timeout_ms = cli_timeout_ms()
  M.run({ "agent", "list" }, function(out, err)
    if not out then
      return cb(nil, err)
    end
    if out.code ~= 0 then
      return cb(nil, safe_error(out, timeout_ms))
    end
    return deliver(cb, M.parse_agent_list, out.stdout)
  end)
end

--- Async `herdr workspace list`; cb(workspaces|nil, err|nil).
---
--- Only labels and the rolled-up state come from here; the agent list is still
--- the authority on which agents exist. A caller that cannot get an answer must
--- degrade to raw workspace ids rather than drop rows (see agents_ui.lua).
---@param cb fun(workspaces: table[]|nil, err: string|nil)
function M.workspace_list(cb)
  local timeout_ms = cli_timeout_ms()
  M.run({ "workspace", "list" }, function(out, err)
    if not out then
      return cb(nil, err)
    end
    if out.code ~= 0 then
      return cb(nil, safe_error(out, timeout_ms))
    end
    return deliver(cb, M.parse_workspace_list, out.stdout)
  end)
end

--- Async `herdr agent get <target>`; cb(agent|nil, err|nil).
---@param target string pane_id of the agent
---@param cb fun(agent: table|nil, err: string|nil)
function M.agent_get(target, cb)
  vim.validate("target", target, "string")
  local timeout_ms = cli_timeout_ms()
  M.run({ "agent", "get", target }, function(out, err)
    if not out then
      return cb(nil, err)
    end
    if out.code ~= 0 then
      return cb(nil, safe_error(out, timeout_ms))
    end
    return deliver(cb, M.parse_agent_get, out.stdout)
  end)
end

return M
