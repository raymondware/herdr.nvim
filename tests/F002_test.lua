-- F002: config schema + deep merge
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F002_test.lua" -c "qa!"

local config = require("herdr.config")

-- 1. Defaults populate M.options via setup({})
config.setup({})
assert(config.options.cmd == "herdr", "default cmd")
assert(config.options.session == nil, "default session is nil")
assert(type(config.options.extra_args) == "table" and #config.options.extra_args == 0, "default extra_args is an empty table")
assert(config.options.window.width == 0.85, "default window.width")
assert(config.options.window.height == 0.85, "default window.height")
assert(config.options.window.border == "rounded", "default window.border")
assert(config.options.window.title == " herdr ", "default window.title")
assert(config.options.terminal.auto_insert == true, "default terminal.auto_insert")
assert(config.options.terminal.persist_buffer == true, "default terminal.persist_buffer")
assert(config.options.terminal.close_on_exit == true, "default terminal.close_on_exit")
assert(config.options.keymaps.toggle == "<C-r>", "default keymaps.toggle")
assert(config.options.keymaps.toggle_in_terminal == true, "default keymaps.toggle_in_terminal")
assert(config.options.keymaps.agents == nil, "default keymaps.agents is nil")
assert(config.options.agents.enabled == true, "default agents.enabled")
assert(config.options.agents.auto_start == true, "default agents.auto_start")
assert(config.options.agents.poll_interval_ms == 5000, "default agents.poll_interval_ms")
assert(config.options.agents.cli_timeout_ms == 4000, "default agents.cli_timeout_ms")
assert(config.options.agents.max_failures == 3, "default agents.max_failures")
assert(config.options.lualine.icons.working == "●", "default lualine.icons.working")
assert(config.options.lualine.icons.blocked == "▲", "default lualine.icons.blocked")
assert(config.options.lualine.icons.done == "✓", "default lualine.icons.done")
assert(config.options.lualine.icons.idle == "○", "default lualine.icons.idle")
-- {idle} is part of the default on purpose: an all-idle fleet is a real state,
-- and without the token hide_when_zero would render "" and hide the component.
assert(config.options.lualine.format == "{working} {blocked} {done} {idle}", "default lualine.format")
assert(config.options.lualine.hide_when_zero == true, "default lualine.hide_when_zero")
assert(config.options.lualine.show_when_idle == false, "default lualine.show_when_idle")

-- agents_window and lualine.show_when_idle are real defaults, not module-local
-- fallbacks: README and doc/herdr.txt document them inside the defaults block.
assert(config.options.agents_window.width == 72, "default agents_window.width")
assert(config.options.agents_window.height == 0.5, "default agents_window.height")
assert(config.options.agents_window.border == "rounded", "default agents_window.border")
assert(config.options.agents_window.title == " herdr agents ", "default agents_window.title")

-- setup() with no argument behaves like setup({})
config.setup()
assert(config.options.cmd == "herdr", "setup() without args uses defaults")

-- 2. Deep merge preserves sibling keys
config.setup({ window = { width = 0.5 } })
assert(config.options.window.width == 0.5, "override window.width")
assert(config.options.window.height == 0.85, "sibling window.height kept")
assert(config.options.window.border == "rounded", "sibling window.border kept")

-- 3. Explicit false round-trips (not replaced by the default string)
config.setup({ keymaps = { toggle = false } })
assert(config.options.keymaps.toggle == false, "keymaps.toggle = false round-trips")
assert(config.options.keymaps.toggle_in_terminal == true, "sibling keymap default kept")

-- 4. Partial nested override keeps other nested defaults
config.setup({ agents = { poll_interval_ms = 100 } })
assert(config.options.agents.poll_interval_ms == 100, "override agents.poll_interval_ms")
assert(config.options.agents.enabled == true, "sibling agents.enabled kept")
assert(config.options.agents.max_failures == 3, "sibling agents.max_failures kept")

-- 5. Repeated setup() is idempotent: re-merged from defaults, not from the
-- previous options table, so earlier overrides do not leak
config.setup({})
assert(config.options.keymaps.toggle == "<C-r>", "previous false override did not leak")
assert(config.options.window.width == 0.85, "previous width override did not leak")
assert(config.options.agents.poll_interval_ms == 5000, "previous poll override did not leak")

-- 6. Defaults table itself is never mutated by any merge
assert(config.defaults.cmd == "herdr", "defaults.cmd untouched")
assert(config.defaults.window.width == 0.85, "defaults.window.width untouched")
assert(config.defaults.keymaps.toggle == "<C-r>", "defaults.keymaps.toggle untouched")
assert(config.defaults.agents.poll_interval_ms == 5000, "defaults.agents.poll_interval_ms untouched")

-- Mutating merged options must not write through into defaults
config.setup({})
config.options.lualine.icons.working = "X"
config.options.window.width = 0.1
assert(config.defaults.lualine.icons.working == "●", "defaults.lualine.icons isolated from options mutation")
assert(config.defaults.window.width == 0.85, "defaults.window isolated from options mutation")

print("PASS: F002 config defaults, deep merge, false round-trip")
