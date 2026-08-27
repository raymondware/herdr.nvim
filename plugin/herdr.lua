if vim.g.loaded_herdr then
  return
end
vim.g.loaded_herdr = true

-- Real commands are registered by require("herdr").setup(); this reminder
-- exists so :HerdrSetup explains itself before the user has configured anything.
vim.api.nvim_create_user_command("HerdrSetup", function()
  vim.notify(
    'Call require("herdr").setup({}) in your init.lua',
    vim.log.levels.WARN,
    { title = "herdr" }
  )
end, { desc = "herdr setup reminder" })
