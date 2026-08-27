-- Lualine component for the herdr agent counts.
--
-- WHY this module is paranoid about cost and errors: lualine evaluates a
-- component on every statusline redraw (many times a second while typing), and
-- an error thrown from that callback breaks the user's whole statusline, not
-- just this plugin. So every entry point reads ONLY the cached
-- agents.counts() - no subprocess, no vim.system, no polling, no per-redraw
-- table building beyond the one output string - and every body runs behind
-- pcall with a quiet fallback.
--
-- Polling is somebody else's job on purpose (init.setup() with
-- agents.auto_start, or agents_ui.open()); a statusline must never be the thing
-- that spawns work.

local agents = require("herdr.agents")
local config = require("herdr.config")

local M = {}

-- Last-resort answer for a key config.lua somehow does not carry (a hand-built
-- config.defaults, a partially loaded module). config.lua owns the real
-- defaults; this only keeps a lookup from returning nil mid-redraw.
local FALLBACK_OPTS = {
  show_when_idle = false,
}

-- Prefix for the degraded text. The counts on screen are frozen, so they must
-- not read as live ones; "!" is one column, survives any 'encoding', and needs
-- no highlight group of its own (color() already switches to the error color).
local DEGRADED_PREFIX = "!"

-- Degraded with nothing to count (no cache yet, or hide_when_zero collapsed
-- every token) still has to say something: an empty string would hide the
-- component at exactly the moment the user needs to know polling gave up.
local DEGRADED_EMPTY = DEGRADED_PREFIX .. " herdr stopped"

-- Highest-severity state -> builtin group the color is borrowed from. Mirrors
-- hl.lua so the statusline and the agents float agree on what red means.
local SEVERITY_HL = {
  blocked = "DiagnosticError",
  working = "DiagnosticWarn",
  ok = "DiagnosticOk",
}

-- Used when the resolved group carries no fg (a cleared group, or a
-- colorscheme that only sets bg). Any plausible hex beats erroring or handing
-- lualine a nil color mid-redraw.
local FALLBACK_FG = {
  blocked = "#f7768e",
  working = "#e0af68",
  ok = "#9ece6a",
}

--- config.options is {} until setup() runs, so every read falls back to
--- defaults and then to FALLBACK_OPTS. Same convention as cli.lua/agents.lua.
---@param key string
local function lualine_opt(key)
  local opts = config.options.lualine
  if type(opts) ~= "table" then
    opts = config.defaults.lualine
  end
  local value = opts[key]
  if value == nil then
    value = config.defaults.lualine[key]
  end
  if value == nil then
    value = FALLBACK_OPTS[key]
  end
  return value
end

---@return table<string, string>
local function icons()
  local configured = lualine_opt("icons")
  if type(configured) ~= "table" then
    return config.defaults.lualine.icons
  end
  return configured
end

---@return string
local function template()
  local configured = lualine_opt("format")
  if type(configured) ~= "string" then
    return config.defaults.lualine.format
  end
  return configured
end

--- Expand `{state}` tokens to "<icon> <count>". A token with no icon (notably
--- `{total}`, which is a tally rather than a state) renders the bare count.
--- Unknown tokens expand to nothing rather than leaking braces into the
--- statusline.
---@param counts table from agents.counts()
---@param hide_when_zero boolean
---@return string
local function render(counts, hide_when_zero)
  local icon_map = icons()
  local text = template():gsub("{(%w+)}", function(token)
    local count = counts[token]
    if count == nil then
      return ""
    end
    if count == 0 and hide_when_zero then
      return ""
    end
    local icon = icon_map[token]
    if type(icon) == "string" and icon ~= "" then
      return icon .. " " .. count
    end
    return tostring(count)
  end)
  -- Dropped tokens leave runs of whitespace behind, and lualine renders them
  -- verbatim, so collapse and trim: no double space, no leading/trailing gap.
  text = text:gsub("%s+", " ")
  return vim.trim(text)
end

local function compute_text()
  local text = render(agents.counts(), lualine_opt("hide_when_zero") ~= false)
  if not agents.is_degraded() then
    return text
  end
  if text == "" then
    return DEGRADED_EMPTY
  end
  return DEGRADED_PREFIX .. " " .. text
end

--- Formatted counts string, or "" when there is nothing worth showing.
--- Safe before require("herdr").setup() and guaranteed not to throw.
---@return string
function M.component_text()
  local ok, text = pcall(compute_text)
  if not ok or type(text) ~= "string" then
    return ""
  end
  return text
end

--- Which state drives the color. is_degraded() takes precedence and borrows the
--- blocked (error) color deliberately: the numbers on screen are frozen stale
--- and polling gave up, which is at least as actionable as a blocked agent, and
--- a second color for "the data is lying to you" would need a new highlight
--- group the plugin does not own. compute_cond() keeps the component visible
--- while degraded, which is what makes this branch reachable at all.
---@return string
local function severity()
  if agents.is_degraded() then
    return "blocked"
  end
  local counts = agents.counts()
  if counts.blocked > 0 then
    return "blocked"
  end
  if counts.working > 0 then
    return "working"
  end
  return "ok"
end

---@param state string key into SEVERITY_HL / FALLBACK_FG
---@return string hex "#rrggbb"
local function fg_hex(state)
  -- link = false resolves through links so a linked group still yields a real
  -- fg; nvim_get_hl (not synIDattr) because synIDattr is the pre-0.9 API.
  local group = vim.api.nvim_get_hl(0, { name = SEVERITY_HL[state], link = false })
  local fg = group and group.fg
  if type(fg) == "number" then
    return ("#%06x"):format(fg)
  end
  if type(fg) == "string" then
    return fg
  end
  return FALLBACK_FG[state]
end

local function compute_color()
  local state = severity()
  return { fg = fg_hex(state) }
end

local function compute_cond()
  -- Degradation is SHOWN, not hidden, and this test has to come first because
  -- is_degraded() implies not is_polling(): degrading is what stops the timer.
  -- Hiding here (the obvious reading of the is_polling() test below) made the
  -- segment vanish at exactly the moment something went wrong, which is the
  -- least informative possible outcome. The text carries a "!" marker and the
  -- color switches to the error color, so frozen counts cannot pass for live
  -- ones.
  if agents.is_degraded() then
    return true
  end
  -- Nothing is refreshing the counts, so showing them would be a lie.
  if not agents.is_polling() then
    return false
  end
  if M.component_text() == "" then
    return false
  end
  if not lualine_opt("show_when_idle") and agents.counts().total == 0 then
    return false
  end
  return true
end

---@return boolean
local function cond()
  local ok, visible = pcall(compute_cond)
  if not ok then
    return false
  end
  return visible == true
end

---@return table {fg = "#rrggbb"}
local function color()
  local ok, value = pcall(compute_color)
  if not ok or type(value) ~= "table" then
    return { fg = FALLBACK_FG.ok }
  end
  return value
end

--- Component spec for direct insertion into a lualine section, e.g.
--- `sections = { lualine_x = { require("herdr.lualine").component() } }`.
---@return table
function M.component()
  return {
    function()
      return M.component_text()
    end,
    cond = cond,
    color = color,
  }
end

return M
