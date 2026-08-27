-- F001: plugin/ entry point with load guard and :HerdrSetup reminder

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- plugin/herdr.lua is auto-sourced from rtp at startup
assert(vim.g.loaded_herdr == true, "vim.g.loaded_herdr should be true after startup")

-- :HerdrSetup exists before any setup() call
assert(vim.fn.exists(":HerdrSetup") == 2, ":HerdrSetup should exist before setup()")

-- :HerdrSetup notifies with the setup reminder
local captured
local orig_notify = vim.notify
vim.notify = function(msg, ...)
  captured = msg
end
local ok_cmd, cmd_err = pcall(vim.cmd, "HerdrSetup")
vim.notify = orig_notify
assert(ok_cmd, "HerdrSetup should not error: " .. tostring(cmd_err))
assert(type(captured) == "string", "HerdrSetup should call vim.notify")
assert(
  captured:find("require", 1, true) and captured:find("herdr", 1, true) and captured:find("setup", 1, true),
  "notify message should mention require('herdr').setup, got: " .. tostring(captured)
)

-- Sourcing the entry point a second time must be a no-op (guard prevents E174)
local ok_resource, resource_err = pcall(vim.cmd, "source " .. plugin_root .. "/plugin/herdr.lua")
assert(ok_resource, "re-sourcing plugin/herdr.lua should not error: " .. tostring(resource_err))
assert(vim.fn.exists(":HerdrSetup") == 2, ":HerdrSetup should still be a single command")

-- Entry point must not force-require lua/herdr modules
assert(
  package.loaded["herdr"] == nil or type(package.loaded["herdr"]) == "table",
  "package.loaded['herdr'] should be nil or a table"
)
assert(package.loaded["herdr.agents"] == nil, "plugin/ must not require lua/herdr modules")

print("PASS: F001 load guard and :HerdrSetup reminder")
