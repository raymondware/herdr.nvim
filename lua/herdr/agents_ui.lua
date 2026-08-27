-- :HerdrAgents read-only floating list of the agents herdr knows about, grouped
-- by the workspace they live in.
--
-- The agent list comes from herdr.agents (the only poller) and this module never
-- polls it. It subscribes with agents.on_update on open and MUST release that
-- subscription on close, including when the window disappears behind its back
-- (user :q, :close, nvim_win_close), hence the WinClosed / BufWipeout autocmds.
-- A surviving listener would keep re-rendering a wiped buffer forever.
--
-- The two things this module DOES fetch itself are both one-shot lookups tied to
-- a user action rather than to a clock: `herdr agent get` for the detail float
-- (below) and `herdr workspace list` for the group headers (see `workspaces`).
-- Neither owns a timer - agents.lua is the sole timer owner in this plugin.
--
-- close() deliberately does NOT stop polling: other consumers (the lualine
-- component) still want fresh counts after the float is dismissed.
--
-- <CR> opens a second, smaller float with one agent's details. That float is a
-- SNAPSHOT: it runs a single cli.agent_get and never subscribes to on_update, so
-- it cannot leak a listener and never repaints under the reader.

local agents = require("herdr.agents")
local cli = require("herdr.cli")
local config = require("herdr.config")
local hl = require("herdr.hl")

local M = {}

-- config.lua owns these defaults; this table is the source of any sub-key a
-- partial user table omits, and a last resort if the lookup finds no table at
-- all. Keep it in sync with config.defaults.agents_window.
local WINDOW_DEFAULTS = {
  width = 72, -- absolute columns (values <= 1 are read as fractions)
  height = 0.5,
  border = "rounded",
  title = " herdr agents ",
}

local STATE_HL = {
  working = "HerdrAgentWorking",
  blocked = "HerdrAgentBlocked",
  done = "HerdrAgentDone",
  idle = "HerdrAgentIdle",
  unknown = "HerdrAgentIdle",
}

-- Worst state first. The index IS the precedence: it decides which state a
-- workspace header rolls up to when herdr did not report one, and it sorts the
-- agents inside a group so the row that wants attention is the group's top row.
local STATE_ORDER = { "blocked", "working", "done", "idle", "unknown" }

local STATE_RANK = {}
for rank, name in ipairs(STATE_ORDER) do
  STATE_RANK[name] = rank
end

local EMPTY_LINE = "No agents"

-- Bucket for agents herdr reported without a workspace_id. They are grouped and
-- rendered like any other workspace rather than dropped: an agent with a broken
-- parent is exactly the one worth seeing.
local UNKNOWN_WORKSPACE = "(unknown workspace)"

-- Column budget of one frame, in display cells. Sized for the default 72-column
-- float (config.defaults.agents_window.width):
--
--    workspace header:  " " + <label (id)> padded to 20 + "<icon> <state>"
--    agent row:         "   " + "<icon> " + name(14) + state(9) + location(12)
--                       + detail
--
-- so a row spends 41 cells before the trailing detail and leaves ~31 for it. The
-- detail is the only cell allowed to overflow, and it overflows off the right
-- edge ('nowrap') instead of pushing any column out of alignment.
local GROUP_INDENT = " "
local AGENT_INDENT = "   "
local WORKSPACE_TITLE_WIDTH = 20
local NAME_WIDTH = 14
local STATE_WIDTH = 9
local LOCATION_WIDTH = 12

local DETAIL_LOADING = "loading..."

-- The detail float is deliberately smaller than the list in BOTH dimensions so
-- the list stays visible behind it. Fractions are of the list float's own size.
local DETAIL_SCALE = {
  width = 0.8,
  height = 0.7,
  min_width = 34,
  min_height = 5,
}

-- Label column of the key: value rows. The widest label is "workspace:" at 10
-- bytes, so 11 guarantees at least one space before every value.
local DETAIL_LABEL_WIDTH = 11

-- Single generation of UI state; unsubscribe is the handle returned by
-- agents.on_update and is niled the moment it is called so double teardown is
-- harmless. rows maps a 1-based buffer line to the agent rendered there, which
-- is how <CR> resolves its target without parsing display text back apart.
local state = {
  buf = nil, ---@type integer|nil
  win = nil, ---@type integer|nil
  unsubscribe = nil, ---@type fun()|nil
  rows = {}, ---@type table<integer, table>
}

-- The detail float. token is a generation counter: an agent_get response whose
-- token is stale (the float was closed or retargeted while the request was out)
-- paints nothing.
local detail = {
  buf = nil, ---@type integer|nil
  win = nil, ---@type integer|nil
  token = 0,
}

-- Workspace metadata for the group headers: the label to name a group by, and
-- herdr's own rolled-up agent_status for it. Keyed by workspace_id.
--
-- WHY the lookup lives here and not in agents.lua's poll: agents.lua owns the one
-- timer and the one measured subprocess per interval, and that is a cost every
-- user pays for as long as nvim is running. Workspace labels are only interesting
-- while this float is on screen, so the float pays for them - one
-- `herdr workspace list` when it opens, and one per poll update it receives while
-- it stays open. No new timer, and nothing per redraw: render() reads this table
-- and never spawns.
--
-- WHY it is refreshed per poll instead of fetched once: the label is stable, but
-- `agent_status` is a rollup of the very rows printed underneath the header, so a
-- cache that outlived a poll would print a header contradicting its own group.
-- The refresh is async, so one frame can pair fresh rows with the previous poll's
-- rollup for as long as the lookup takes; painting immediately and correcting a
-- few milliseconds later beats holding the agent rows hostage to a second
-- subprocess.
--
-- key is the cli.spawn_key() the cache was filled from. A response from a
-- cmd/session the user has since changed away from describes a DIFFERENT server's
-- workspaces, so it is dropped and the cache is emptied - the same discipline as
-- agents.lua's poll and the detail float's token.
local workspaces = {
  by_id = {}, ---@type table<string, table>
  key = nil, ---@type string|nil
  -- True once any answer (success OR failure) has landed for `key`, so open()
  -- does not re-ask on every open when the lookup is failing.
  answered = false,
  in_flight = false,
}

local hl_ready = false

local augroup = vim.api.nvim_create_augroup("HerdrAgentsUi", { clear = true })

-- init.setup() calls hl.setup(), but the float must also work when opened via
-- a direct require() without setup(). Guarded because setup() also (re)creates
-- an augroup.
local function ensure_hl()
  if hl_ready then
    return
  end
  hl.setup()
  hl_ready = true
end

local function opt(key)
  return config.options[key] or config.defaults[key]
end

local function window_opts()
  local window = config.options.agents_window or config.defaults.agents_window
  if type(window) ~= "table" then
    return WINDOW_DEFAULTS
  end
  -- "keep" so a partial user table still gets every key it omitted.
  return vim.tbl_extend("keep", window, WINDOW_DEFAULTS)
end

-- Same convention as terminal.lua: fractions (<= 1) scale against the editor
-- dimension, larger values are absolute cell counts.
local function scale(value, total)
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
end

---@return table win_config for nvim_open_win / nvim_win_set_config
local function win_config()
  local window = window_opts()
  local has_border = window.border ~= nil and window.border ~= "none"
  -- A border draws one extra cell per side, so the usable area shrinks and the
  -- centering shifts by the same amount.
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

--- Geometry for the detail float: a fraction of the list float, centered on the
--- editor (so it overlaps the list rather than being anchored to it, which keeps
--- it on screen no matter where the list ended up) and drawn above it.
---@param agent table normalized agent, for the window title
---@return table win_config
local function detail_win_config(agent)
  local window = window_opts()
  local list = win_config()
  local has_border = window.border ~= nil and window.border ~= "none"
  local pad = has_border and 2 or 0
  -- The minimums are themselves capped by the list size: on a tiny editor a
  -- fixed floor would make the detail float LARGER than the list.
  local width = math.max(
    math.min(DETAIL_SCALE.min_width, list.width),
    math.floor(list.width * DETAIL_SCALE.width)
  )
  local height = math.max(
    math.min(DETAIL_SCALE.min_height, list.height),
    math.floor(list.height * DETAIL_SCALE.height)
  )
  local cfg = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height - pad) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - pad) / 2)),
    style = "minimal",
    border = window.border,
    -- Above the list float, which sits at the default 50.
    zindex = 60,
  }
  if has_border then
    cfg.title = (" agent: %s "):format(agent.name or "?")
    cfg.title_pos = "center"
  end
  return cfg
end

---@param agent_state string
---@return string
local function icon_for(agent_state)
  local icons = opt("lualine").icons or config.defaults.lualine.icons
  return icons[agent_state] or icons.idle or "*"
end

--- Trailing context for one row: where the agent works, else what it is.
---
--- The flat list ended this chain with `agent.target` (the pane id). Grouping
--- moved the pane id into its own location column, so keeping it here would fill
--- the widest cell on the line with a duplicate of a narrower one.
---@param agent table normalized agent from cli.normalize_agent
---@return string
local function detail_for(agent)
  local raw = type(agent.detail) == "table" and agent.detail or {}
  return raw.cwd or raw.terminal_title or agent.kind or ""
end

--- Pad `text` out to `width` DISPLAY cells, with at least one trailing space.
---
--- Display cells, not bytes: labels and agent names are user-supplied and may be
--- multibyte, and %-Ns would align them by byte length. Nothing is ever
--- truncated - a value wider than its column pushes the rest of the line right,
--- which is visibly odd but never hides characters the user needs.
---@param text string
---@param width integer
---@return string
local function pad(text, width)
  local gap = width - vim.fn.strdisplaywidth(text)
  return text .. string.rep(" ", gap > 0 and gap or 1)
end

--- Drop the redundant `<workspace_id>:` prefix from a hierarchical herdr id.
--- Under a workspace header, a tab of `w5:t1` and a pane of `w5:p2` say
--- "workspace w5" three times on one screen; the row only needs `t1:p2`.
---@param id any raw tab_id/pane_id
---@param workspace_id string|nil the group this row is rendered under
---@return string|nil
local function strip_workspace(id, workspace_id)
  if type(id) ~= "string" or id == "" then
    return nil
  end
  if type(workspace_id) == "string" and workspace_id ~= "" then
    local prefix = workspace_id .. ":"
    if id:sub(1, #prefix) == prefix then
      return id:sub(#prefix + 1)
    end
  end
  return id
end

--- Where one agent sits inside its workspace, as `<tab>:<pane>`.
---@param agent table normalized agent from cli.normalize_agent
---@param workspace_id string|nil
---@return string
local function location_for(agent, workspace_id)
  local raw = type(agent.detail) == "table" and agent.detail or {}
  local tab = strip_workspace(raw.tab_id, workspace_id)
  local pane = strip_workspace(raw.pane_id or agent.target, workspace_id)
  if tab and pane then
    return tab .. ":" .. pane
  end
  return tab or pane or ""
end

---@param agent_state any
---@return integer
local function state_rank(agent_state)
  return STATE_RANK[agent_state] or STATE_RANK.unknown
end

---@param counts table from agents.counts()
---@return string
local function header_text(counts)
  local parts = {
    ("%d agent%s"):format(counts.total, counts.total == 1 and "" or "s"),
    ("%d working"):format(counts.working),
    ("%d blocked"):format(counts.blocked),
    ("%d done"):format(counts.done),
  }
  -- Idle/unknown are noise at zero but matter when they are not.
  if counts.idle > 0 then
    parts[#parts + 1] = ("%d idle"):format(counts.idle)
  end
  if counts.unknown > 0 then
    parts[#parts + 1] = ("%d unknown"):format(counts.unknown)
  end
  return table.concat(parts, "  ")
end

--- Spawn one `herdr workspace list` and fold the answer into the cache.
---
--- At most one request is out at a time. A failure is deliberately swallowed:
--- labels are decoration on top of the agent list, so a lookup that cannot answer
--- must cost the user nothing more than seeing `w5` instead of `rware (w5)`. It
--- adds no notice line of its own (that would shift every row for a cosmetic
--- problem) and it never touches the agent rows.
local function fetch_workspaces()
  local key = cli.spawn_key()
  -- Checked before the in-flight guard: the moment anything notices the server
  -- changed, the previous server's labels must stop being rendered, whether or
  -- not a request happens to be out.
  if key ~= workspaces.key then
    workspaces.by_id, workspaces.answered, workspaces.key = {}, false, key
  end
  if workspaces.in_flight then
    return
  end
  workspaces.in_flight = true
  cli.workspace_list(function(list, _err)
    workspaces.in_flight = false
    if key ~= cli.spawn_key() then
      return
    end
    workspaces.answered = true
    if list then
      local by_id = {}
      for _, workspace in ipairs(list) do
        by_id[workspace.workspace_id] = workspace
      end
      workspaces.by_id = by_id
    end
    if M.is_open() then
      M.render()
    end
  end)
end

--- Fetch workspace metadata only if this server has never answered. Used on open,
--- where a cache filled a moment ago is good enough for the first frame.
local function ensure_workspaces()
  if workspaces.answered and workspaces.key == cli.spawn_key() then
    return
  end
  fetch_workspaces()
end

--- Workspace metadata that provably describes the server the agent list came
--- from, or an empty table.
---@return table<string, table>
local function known_workspaces()
  if workspaces.key ~= cli.spawn_key() then
    return {}
  end
  return workspaces.by_id
end

--- Rolled-up state derived from a group's own rows, worst state wins.
---
--- WHY this exists at all: `herdr workspace list` reports an `agent_status` per
--- workspace and that is what a header shows when it is available, but a workspace
--- can be missing from that call entirely (the lookup failed, or herdr knows an
--- agent in a workspace the list did not return). Deriving from the rows keeps the
--- header truthful instead of stamping every such group "unknown".
---@param list table[] agents in the group
---@return string
local function derived_state(list)
  local best = nil
  for _, agent in ipairs(list) do
    local rank = state_rank(agent.state)
    if best == nil or rank < best then
      best = rank
    end
  end
  return STATE_ORDER[best or 0] or "unknown"
end

--- Group agents by workspace, in a deterministic order.
---
--- ORDERING, so two polls that returned the same fleet render byte-identically:
--- workspaces `herdr workspace list` knows come first, ascending by `number`
--- (herdr's own workspace ordering, which is what the TUI shows); then
--- workspaces it does not know, which have no number to sort by, ascending by
--- workspace_id; then the single "(unknown workspace)" bucket, always last.
--- Inside a group: worst state first (blocked > working > done > idle > unknown),
--- then name, then pane id. The pane id tiebreak makes the order total - two
--- agents can share a display name, but not a pane.
---@param list table[] normalized agents
---@param ws_by_id table<string, table>
---@return table[] groups {id, info, rank, number, agents}
local function group_by_workspace(list, ws_by_id)
  local groups, index = {}, {}
  for _, agent in ipairs(list) do
    local raw = type(agent.detail) == "table" and agent.detail or {}
    local id = raw.workspace_id
    if type(id) ~= "string" or id == "" then
      id = nil
    end
    -- "\0" cannot appear in a herdr id, so the bucket key cannot collide.
    local key = id or "\0unknown"
    local group = index[key]
    if not group then
      local info = id and ws_by_id[id] or nil
      local number = info and info.number or nil
      group = {
        id = id,
        info = info,
        rank = (id == nil) and 3 or (number and 1 or 2),
        number = number or 0,
        agents = {},
      }
      index[key] = group
      groups[#groups + 1] = group
    end
    group.agents[#group.agents + 1] = agent
  end

  table.sort(groups, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    if a.rank == 1 and a.number ~= b.number then
      return a.number < b.number
    end
    return (a.id or "") < (b.id or "")
  end)

  for _, group in ipairs(groups) do
    table.sort(group.agents, function(a, b)
      local rank_a, rank_b = state_rank(a.state), state_rank(b.state)
      if rank_a ~= rank_b then
        return rank_a < rank_b
      end
      local name_a, name_b = a.name or "", b.name or ""
      if name_a ~= name_b then
        return name_a < name_b
      end
      return (a.target or "") < (b.target or "")
    end)
  end

  return groups
end

--- Header text for one group. The workspace id is ALWAYS visible, because herdr
--- labels are not unique: several workspaces really are called "rware", and a
--- header showing only the label would be a header the user cannot act on.
---@param group table
---@return string
local function group_title(group)
  if not group.id then
    return UNKNOWN_WORKSPACE
  end
  local label = group.info and group.info.label
  if type(label) == "string" and vim.trim(label) ~= "" then
    return ("%s (%s)"):format(label, group.id)
  end
  return group.id
end

--- The state a group's header rolls up to: herdr's own if it reported one for
--- this workspace, else derived from the group's rows.
---@param group table
---@return string
local function group_state(group)
  local reported = group.info and group.info.state
  if type(reported) == "string" and STATE_RANK[reported] then
    return reported
  end
  return derived_state(group.agents)
end

--- Build the whole frame: display lines, the extmarks that colorize them, and
--- the line -> agent map <CR> resolves against. Byte offsets are tracked while
--- the line is assembled because the state icons are multibyte and extmark
--- columns are byte columns.
---@return string[] lines, table[] marks {row, col, end_col, hl_group}, table<integer, table> rows
local function build()
  local list = agents.get()
  local counts = agents.counts()
  local lines = { header_text(counts) }
  local marks = { { row = 0, col = 0, end_col = #lines[1], hl_group = "HerdrHeader" } }
  -- Only real agent lines get an entry, which is what makes <CR> on the global
  -- header, a workspace header, a blank separator, the degraded line and the
  -- empty-state line a no-op.
  local rows = {}

  lines[#lines + 1] = ""

  if agents.is_degraded() then
    local text = ("polling stopped: %s"):format(agents.last_error() or "unknown herdr error")
    lines[#lines + 1] = text
    marks[#marks + 1] = {
      row = #lines - 1,
      col = 0,
      end_col = #text,
      hl_group = "HerdrAgentBlocked",
    }
  end

  if #list == 0 then
    lines[#lines + 1] = EMPTY_LINE
    marks[#marks + 1] = {
      row = #lines - 1,
      col = 0,
      end_col = #EMPTY_LINE,
      hl_group = "HerdrAgentIdle",
    }
    return lines, marks, rows
  end

  for i, group in ipairs(group_by_workspace(list, known_workspaces())) do
    -- Separator BEFORE each header but the first, so the frame never ends on a
    -- blank line the cursor can land on.
    if i > 1 then
      lines[#lines + 1] = ""
    end

    local title = group_title(group)
    local title_cell = GROUP_INDENT .. pad(title, WORKSPACE_TITLE_WIDTH)
    local group_state_name = group_state(group)
    local badge = ("%s %s"):format(icon_for(group_state_name), group_state_name)
    lines[#lines + 1] = title_cell .. badge
    marks[#marks + 1] = {
      row = #lines - 1,
      col = #GROUP_INDENT,
      end_col = #GROUP_INDENT + #title,
      hl_group = "HerdrHeader",
    }
    marks[#marks + 1] = {
      row = #lines - 1,
      col = #title_cell,
      end_col = #title_cell + #badge,
      hl_group = STATE_HL[group_state_name] or "HerdrAgentIdle",
    }

    for _, agent in ipairs(group.agents) do
      local agent_state = agent.state or "unknown"
      -- Everything up to the state word, so the state extmark starts at #prefix.
      local prefix = ("%s%s %s"):format(
        AGENT_INDENT,
        icon_for(agent_state),
        pad(agent.name or "?", NAME_WIDTH)
      )
      local line = prefix .. pad(agent_state, STATE_WIDTH)
      local location = location_for(agent, group.id)
      local trailing = detail_for(agent)
      if trailing ~= "" then
        -- Padded even when empty, so the detail column stays put across rows.
        line = line .. pad(location, LOCATION_WIDTH) .. trailing
      else
        line = line .. location
      end
      -- The padding of the last populated cell would otherwise leave the line
      -- ending in spaces the user can put a cursor on.
      line = (line:gsub("%s+$", ""))

      lines[#lines + 1] = line
      rows[#lines] = agent
      marks[#marks + 1] = {
        row = #lines - 1,
        col = #prefix,
        end_col = #prefix + #agent_state,
        hl_group = STATE_HL[agent_state] or "HerdrAgentIdle",
      }
    end
  end

  return lines, marks, rows
end

--- Rows of the detail float: {label, value, value_hl?} with missing optional
--- fields dropped so the reader never scans past a column of placeholders.
--- name and state are always present because both have a fallback.
---@param agent table normalized agent from cli.normalize_agent
---@return table[]
local function detail_rows(agent)
  local raw = type(agent.detail) == "table" and agent.detail or {}
  local agent_state = agent.state or "unknown"
  local candidates = {
    { "name", agent.name or "?" },
    { "state", agent_state, STATE_HL[agent_state] or "HerdrAgentIdle" },
    { "kind", agent.kind },
    { "focused", agent.focused ~= nil and tostring(agent.focused) or nil },
    { "pane", agent.target or raw.pane_id },
    { "tab", raw.tab_id },
    { "workspace", raw.workspace_id },
    { "terminal", raw.terminal_id },
    { "title", raw.title or raw.terminal_title },
    { "cwd", raw.cwd },
  }
  local rows = {}
  for _, row in ipairs(candidates) do
    local value = row[2]
    if value ~= nil and value ~= "" then
      rows[#rows + 1] = { row[1], tostring(value), row[3] }
    end
  end
  return rows
end

--- Detail frame for one fetched agent.
---@param agent table
---@return string[] lines, table[] marks
local function build_detail(agent)
  local lines, marks = {}, {}
  for _, row in ipairs(detail_rows(agent)) do
    local label = row[1] .. ":"
    local prefix = ("%-" .. DETAIL_LABEL_WIDTH .. "s"):format(label)
    lines[#lines + 1] = prefix .. row[2]
    marks[#marks + 1] = {
      row = #lines - 1,
      col = 0,
      end_col = #label,
      hl_group = "HerdrAgentIdle",
    }
    if row[3] then
      marks[#marks + 1] = {
        row = #lines - 1,
        col = #prefix,
        end_col = #prefix + #row[2],
        hl_group = row[3],
      }
    end
  end
  return lines, marks
end

--- Detail frame for a failed lookup. Rendered in place of the fields so the
--- float never sits there blank on the loading line.
---@param err string
---@return string[] lines, table[] marks
local function build_detail_error(err)
  local text = "error: " .. err
  return { text }, { { row = 0, col = 0, end_col = #text, hl_group = "HerdrAgentBlocked" } }
end

---@return boolean
function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

---@return boolean
function M.detail_is_open()
  return detail.win ~= nil and vim.api.nvim_win_is_valid(detail.win)
end

--- Write one frame into a float buffer. A no-op once the buffer is gone, because
--- a poll (or an agent_get response) can land between the window closing and
--- teardown running.
---@param buf integer|nil
---@param lines string[]
---@param marks table[]|nil {row, col, end_col, hl_group}
local function paint(buf, lines, marks)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- The buffer is read-only for the user; modifiable is flipped only for the
  -- duration of the write.
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, hl.ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  for _, mark in ipairs(marks or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, hl.ns, mark.row, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.hl_group,
    })
  end
end

--- Stable identity of a rendered agent, for matching the same agent across a
--- repaint. target (pane_id) is what every other consumer addresses an agent by;
--- the display name is the fallback for an agent herdr reports without a pane.
---@param agent table|nil
---@return string|nil
local function identity(agent)
  if type(agent) ~= "table" then
    return nil
  end
  if type(agent.target) == "string" then
    return "target:" .. agent.target
  end
  if type(agent.name) == "string" then
    return "name:" .. agent.name
  end
  return nil
end

--- 1-based buffer line the cursor sits on in the list float, or nil.
---@return integer|nil
local function cursor_row()
  if not M.is_open() then
    return nil
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, state.win)
  if not ok then
    return nil
  end
  return cursor[1]
end

--- Put the cursor back on the agent it was on before the repaint. A no-op when
--- that agent is gone from the list (nvim clamps the cursor itself).
---@param selected string|nil identity() captured before the repaint
local function restore_cursor(selected)
  if not selected or not M.is_open() then
    return
  end
  for row, agent in pairs(state.rows) do
    if identity(agent) == selected then
      if cursor_row() ~= row then
        pcall(vim.api.nvim_win_set_cursor, state.win, { row, 0 })
      end
      return
    end
  end
end

--- Repaint the list float in place.
---
--- WHY the cursor is carried across the repaint: the degraded notice appears and
--- disappears BETWEEN renders and is drawn above the agent rows, so every agent
--- shifts down a line while the cursor stays put. The row map is rebuilt
--- correctly either way, but the cursor would then address a row the user did not
--- pick - <CR> landing on the notice line (a silent no-op on what looks like the
--- selected agent) or, once the notice clears again, on a different agent.
function M.render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local selected = identity(state.rows[cursor_row() or -1])
  local lines, marks, rows = build()
  state.rows = rows
  paint(state.buf, lines, marks)
  restore_cursor(selected)
end

local function release_listener()
  if not state.unsubscribe then
    return
  end
  local unsubscribe = state.unsubscribe
  state.unsubscribe = nil
  pcall(unsubscribe)
end

--- Forget the detail float and hand its win/buf back, because the caller decides
--- WHEN they can be closed (doing it from inside BufWipeout is not allowed).
--- Bumping the token is what makes an in-flight agent_get response inert.
---@return integer|nil win, integer|nil buf
local function detach_detail()
  local win, buf = detail.win, detail.buf
  detail.win, detail.buf = nil, nil
  detail.token = detail.token + 1
  return win, buf
end

---@param win integer|nil
---@param buf integer|nil
local function dispose(win, buf)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  -- bufhidden = "wipe" normally does this; the explicit delete covers a buffer
  -- that outlived its window (e.g. it was shown somewhere else too).
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function focus_list()
  if M.is_open() then
    pcall(vim.api.nvim_set_current_win, state.win)
  end
end

--- Teardown for a float that went away without close() being called (:q,
--- :close, nvim_win_close, another plugin). Releasing the subscription here is
--- the leak guard: a listener left behind would repaint a wiped buffer. The
--- detail float goes with it so the list can never leave an orphan behind.
local function handle_external_close()
  release_listener()
  local detail_win, detail_buf = detach_detail()
  local win = state.win
  state.win, state.buf = nil, nil
  state.rows = {}
  -- Scheduled because closing a window from inside BufWipeout is not allowed.
  vim.schedule(function()
    dispose(detail_win, detail_buf)
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end)
end

--- Same teardown for the detail float alone. Focus goes back to the list, which
--- is the whole point of the two floats being independent.
local function handle_detail_external_close()
  local win, buf = detach_detail()
  vim.schedule(function()
    dispose(win, buf)
    focus_list()
  end)
end

--- The agent on the cursor line of the list float, or nil on a line that is not
--- an agent (header, separator, degraded notice, empty-state placeholder).
---@return table|nil
local function cursor_agent()
  local row = cursor_row()
  if not row then
    return nil
  end
  return state.rows[row]
end

--- Close the detail float only, and hand focus back to the list. Idempotent.
function M.detail_close()
  local win, buf = detach_detail()
  dispose(win, buf)
  focus_list()
end

--- Open the detail float for `agent`, or for the agent under the cursor in the
--- list float when omitted. Omitted plus a non-agent line is a deliberate no-op.
---
--- The window opens BEFORE the lookup and shows a loading line, so <CR> gives
--- immediate feedback and an error has somewhere to render. A stale response
--- (float closed or retargeted meanwhile) is dropped via the token.
---@param agent table|nil normalized agent from cli.normalize_agent
function M.detail_open(agent)
  vim.validate("agent", agent, "table", true)
  agent = agent or cursor_agent()
  if not agent then
    return
  end

  ensure_hl()
  if M.detail_is_open() then
    -- Retarget by replacing: the window title carries the agent name, and a
    -- fresh buffer cannot show a previous agent's fields.
    M.detail_close()
  end

  detail.token = detail.token + 1
  local token = detail.token

  detail.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[detail.buf].bufhidden = "wipe"
  vim.bo[detail.buf].filetype = "herdr-agent"
  vim.keymap.set("n", "q", M.detail_close, {
    buffer = detail.buf,
    desc = "herdr: close agent detail",
  })
  vim.keymap.set("n", "<Esc>", M.detail_close, {
    buffer = detail.buf,
    desc = "herdr: close agent detail",
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = detail.buf,
    desc = "herdr: drop the agent detail float",
    callback = handle_detail_external_close,
  })

  detail.win = vim.api.nvim_open_win(detail.buf, true, detail_win_config(agent))
  vim.wo[detail.win].wrap = false
  -- WinClosed is pattern-matched on the window id, so it cannot be buffer-local.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(detail.win),
    once = true,
    desc = "herdr: drop the agent detail float",
    callback = handle_detail_external_close,
  })

  paint(detail.buf, { DETAIL_LOADING })

  if type(agent.target) ~= "string" then
    -- normalize_agent maps target from a nullable pane_id, so `herdr agent get`
    -- has nothing to address. Fail in the float instead of throwing out of the
    -- keymap (cli.agent_get validates target as a string).
    paint(detail.buf, build_detail_error("agent has no pane id to look up"))
    return
  end

  local buf = detail.buf
  cli.agent_get(agent.target, function(fetched, err)
    if token ~= detail.token then
      return
    end
    if fetched then
      paint(buf, build_detail(fetched))
    else
      paint(buf, build_detail_error(err or "unknown herdr error"))
    end
  end)
end

local function attach(buf)
  vim.keymap.set("n", "q", M.close, { buffer = buf, desc = "herdr: close agent list" })
  vim.keymap.set("n", "<Esc>", M.close, { buffer = buf, desc = "herdr: close agent list" })
  vim.keymap.set("n", "r", function()
    -- The on_update listener does the repaint when the poll resolves.
    agents.refresh()
  end, { buffer = buf, desc = "herdr: refresh agents" })
  vim.keymap.set("n", "<CR>", function()
    M.detail_open()
  end, { buffer = buf, desc = "herdr: show agent detail" })

  -- Buffer-scoped, so it dies with the buffer. bufhidden = "wipe" makes this
  -- fire for every ordinary way the float can disappear.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = buf,
    desc = "herdr: release the agent list update subscription",
    callback = handle_external_close,
  })
end

--- WinClosed is pattern-matched on the window id, so it cannot be registered
--- buffer-local; `once` keeps stale per-window entries from piling up in the
--- augroup. It covers the case where the buffer survives its window.
local function watch_window(win)
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    once = true,
    desc = "herdr: release the agent list update subscription",
    callback = handle_external_close,
  })
end

--- Open the float (or focus it when it is already up), then subscribe to poll
--- updates and kick a refresh so the first frame is not stale.
function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  ensure_hl()

  state.buf = vim.api.nvim_create_buf(false, true)
  -- "wipe" keeps buffer count flat across open/close cycles; buftype stays
  -- "nofile" from the scratch flag.
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "herdr-agents"
  attach(state.buf)

  state.win = vim.api.nvim_open_win(state.buf, true, win_config())
  vim.wo[state.win].wrap = false
  watch_window(state.win)

  -- Paint whatever is cached (possibly nothing) before any await, so the float
  -- is never blank while the first poll is out. Group headers fall back to raw
  -- workspace ids until the lookup below answers.
  M.render()

  ensure_workspaces()

  state.unsubscribe = agents.on_update(function()
    -- Refreshed with the rows it labels: a workspace's rolled-up agent_status is
    -- exactly as volatile as the states listed under it.
    fetch_workspaces()
    M.render()
  end)

  agents.refresh()

  local agents_opts = opt("agents")
  if agents_opts.enabled and not agents.is_polling() then
    -- Opening the view is an explicit request for live data.
    agents.start()
  end
end

--- Dismiss the float and release the subscription. Polling keeps running: the
--- lualine component may still be consuming it. The detail float is a child of
--- this one, so it goes first: leaving it up would orphan a window whose only
--- way back to the list is gone.
function M.close()
  release_listener()
  dispose(detach_detail())
  local win, buf = state.win, state.buf
  state.win, state.buf = nil, nil
  state.rows = {}
  dispose(win, buf)
end

--- One entry point for :HerdrAgents and the optional keymap.
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- Keep the floats centered and sized when the editor is resized. The detail
-- float has no agent handy here, so its title is left as-is (set_config would
-- drop it otherwise).
vim.api.nvim_create_autocmd("VimResized", {
  group = augroup,
  desc = "herdr: recenter the agent floats",
  callback = function()
    if M.is_open() then
      pcall(vim.api.nvim_win_set_config, state.win, win_config())
    end
    if M.detail_is_open() then
      local cfg = detail_win_config({ name = nil })
      cfg.title = vim.api.nvim_win_get_config(detail.win).title
      pcall(vim.api.nvim_win_set_config, detail.win, cfg)
    end
  end,
})

return M
