-- Shared test helpers. Not a test file: the runner globs tests/F0*.lua, so this
-- file is only ever pulled in explicitly, e.g.
--
--   local helpers = dofile(
--     vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
--
-- (dofile with a path derived from the requiring script, because the test files
-- are loaded by absolute/relative path and never through package.path.)

local M = {}

--- Census of live libuv timer handles in this process.
---
--- WHY this exists: "a leaked uv timer would hang headless nvim on exit" is
--- FALSE on nvim 0.12. Mutants leaving 30 stopped-but-unclosed timers, and even
--- 30 still-ACTIVE timers firing forever, both let nvim exit in ~600ms and both
--- passed the whole suite. Clean exit proves nothing about handle hygiene, so the
--- only way to assert it is to count the handles.
---
--- `is_closing()` is the filter that matters: a handle is excluded the moment
--- close() is called on it, which is exactly the difference between agents.stop()
--- (stop + close) and a leak (stop only).
---
--- PRECONDITION: this counts every timer in the process, not just the plugin's,
--- so assert_no_live_timers() is only meaningful under tests/minimal-init.lua,
--- where the baseline is 0 (verified: 0 with herdr unloaded, 1 while polling, 0
--- after cleanup). Under a full user config nvim's own internals hold 13 or more
--- timers and the absolute assertion is meaningless there.
---
--- CAVEAT: an in-flight `vim.system` call with a timeout holds one live uv timer
--- of its own (verified), so a census taken while a subprocess is out is not
--- about the plugin. assert_no_live_timers() waits that out instead of racing it.
---@return integer live, integer active
function M.timer_census()
  local live, active = 0, 0
  vim.uv.walk(function(handle)
    if
      handle
      and type(handle.get_type) == "function"
      and handle:get_type() == "timer"
      and not handle:is_closing()
    then
      live = live + 1
      if handle:is_active() then
        active = active + 1
      end
    end
  end)
  return live, active
end

--- Assert no live uv timer remains.
---
--- The wait tolerates a transient timer owned by an in-flight vim.system call
--- (it disappears when the subprocess is reaped) while still failing a real
--- leak, which never disappears no matter how long the loop is pumped.
---@param label string what is being asserted, for the failure message
---@param timeout_ms integer|nil default 3000
function M.assert_no_live_timers(label, timeout_ms)
  local live, active = M.timer_census()
  local settled = vim.wait(timeout_ms or 3000, function()
    live, active = M.timer_census()
    return live == 0
  end, 20)
  assert(
    settled,
    ("%s: %d live uv timer handle(s) left, %d of them still active"):format(label, live, active)
  )
end

return M
