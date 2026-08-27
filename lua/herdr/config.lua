local M = {}

M.defaults = {
  -- herdr binary name or path; tests point this at tests/fixtures stubs
  cmd = "herdr",
  -- Named herdr session; appended as `--session <name>` to the TUI command
  session = nil,
  -- Extra argv appended to the TUI command (terminal.build_cmd reads this)
  extra_args = {},

  window = {
    width = 0.85, -- fraction of columns
    height = 0.85, -- fraction of lines
    border = "rounded",
    title = " herdr ",
  },

  -- Geometry of the :HerdrAgents float. Same rule as `window`: values <= 1 are
  -- fractions of the editor, larger values are absolute cells.
  agents_window = {
    width = 72,
    height = 0.5,
    border = "rounded",
    title = " herdr agents ",
  },

  terminal = {
    auto_insert = true,
    -- Toggle hides the window and keeps buffer + client job; false kills on toggle
    persist_buffer = true,
    -- Close float and wipe buffer when the herdr client exits or detaches
    close_on_exit = true,
  },

  keymaps = {
    -- Shadows redo in normal mode (documented); false disables so a lazy
    -- `keys` spec can own the mapping instead
    toggle = "<C-r>",
    toggle_in_terminal = true,
    agents = nil, -- optional normal-mode key for :HerdrAgents
  },

  agents = {
    enabled = true,
    -- Start polling from setup() (else first UI open starts it)
    auto_start = true,
    poll_interval_ms = 5000,
    cli_timeout_ms = 4000,
    -- Consecutive failures before polling self-stops (degraded)
    max_failures = 3,
  },

  lualine = {
    icons = {
      working = "●",
      blocked = "▲",
      done = "✓",
      idle = "○",
    },
    -- Component template; each token becomes icon+count for that state.
    -- {idle} is in the default on purpose: a fleet that is entirely idle is a
    -- real and common state, and without it hide_when_zero renders "" and the
    -- component disappears while the agents float still lists agents.
    format = "{working} {blocked} {done} {idle}",
    hide_when_zero = true,
    -- Show the component when herdr knows about no agents at all. Only
    -- reachable with hide_when_zero = false, since otherwise the all-zero text
    -- is already empty.
    show_when_idle = false,
  },
}

M.options = {}

function M.setup(opts)
  -- Re-merge from defaults (not previous options) so repeated setup() calls
  -- are idempotent and stale overrides never leak between calls. The deepcopy
  -- matters: tbl_deep_extend shares un-overridden subtables by reference, and
  -- a shared reference would let later mutation of options corrupt defaults.
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
