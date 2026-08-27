-- Minimal init for headless testing of herdr.nvim
-- Usage: timeout 15 nvim --headless -u tests/minimal-init.lua -c "luafile tests/F00X_test.lua" -c "qa!"

-- Add plugin to runtime path
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

-- Put stub fixtures first on $PATH so tests can set cmd = "herdr-stub" etc.
vim.env.PATH = plugin_root .. "/tests/fixtures:" .. vim.env.PATH

-- Minimal settings for testing
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
