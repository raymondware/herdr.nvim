-- Highlight groups and the single extmark namespace for the whole plugin.
--
-- Every group is created with `default = true` links so a user colorscheme (or
-- an explicit :highlight in the user's config) always wins; the plugin only
-- supplies a sane fallback. Some colorschemes clear non-builtin groups when
-- they load, so the links are re-applied on ColorScheme.

local M = {}

-- state name -> builtin group the plugin borrows its colors from.
local GROUPS = {
  HerdrAgentWorking = "DiagnosticWarn",
  HerdrAgentBlocked = "DiagnosticError",
  HerdrAgentDone = "DiagnosticOk",
  HerdrAgentIdle = "Comment",
  HerdrHeader = "Title",
}

-- The one namespace in the plugin. nvim_create_namespace is idempotent per
-- name, so resolving it at require() time is both cheap and stable, and it
-- lets consumers use `hl.ns` directly as an extmark namespace id.
M.ns = vim.api.nvim_create_namespace("herdr")

--- Namespace accessor for callers that prefer a function over the field.
---@return integer
function M.get_ns()
  return M.ns
end

local function apply()
  for name, link in pairs(GROUPS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

--- Define the highlight groups and keep them alive across colorscheme
--- switches. Idempotent: re-applying a default link is a no-op, and the
--- augroup is cleared so repeated calls cannot stack autocmds.
function M.setup()
  apply()
  local augroup = vim.api.nvim_create_augroup("HerdrHl", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    desc = "herdr: re-apply default highlight links after a colorscheme change",
    callback = apply,
  })
end

return M
