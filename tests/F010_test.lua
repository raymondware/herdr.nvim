-- F010: the lualine component (shape, format tokens, hide_when_zero,
-- severity color, degraded behavior, pre-setup safety).
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F010_test.lua" -c "qa!"
--
-- Section 1 MUST stay first: it asserts the module is safe before any setup()
-- call, which is only observable while config.options is still empty.

local ll = require("herdr.lualine")

-- 1. Pre-setup: no config, no polling, nothing throws, nothing renders.
assert(ll.component_text() == "", "component_text() is empty before setup()")

local comp = ll.component()
assert(type(comp) == "table", "component() returns a table")
assert(type(comp[1]) == "function", "component()[1] is the text function")
assert(type(comp.cond) == "function", "component().cond is a function")
assert(type(comp.color) == "function", "component().color is a function")
assert(comp[1]() == "", "component()[1]() is empty before setup()")
assert(comp.cond() == false, "cond() is false while nothing is polling")

local hex_ok, pre_color = pcall(comp.color)
assert(hex_ok, "color() does not throw before setup()")
assert(
  type(pre_color) == "table" and type(pre_color.fg) == "string" and pre_color.fg:match("^#%x%x%x%x%x%x$"),
  "color() returns a #rrggbb fg before setup(): " .. vim.inspect(pre_color)
)

local agents = require("herdr.agents")
local config = require("herdr.config")
local ICONS = config.defaults.lualine.icons

-- Degradation warns; keep headless output to the PASS line.
local original_notify = vim.notify
vim.notify = function() end

-- Mirrors lualine.lua's resolution rule on purpose: the assertions below are
-- about the component agreeing with the Diagnostic groups, and the hardcoded
-- fallbacks are part of the documented contract when a group has no fg.
local FALLBACK_FG = { blocked = "#f7768e", working = "#e0af68", ok = "#9ece6a" }
local SEVERITY_HL = {
  blocked = "DiagnosticError",
  working = "DiagnosticWarn",
  ok = "DiagnosticOk",
}

local function expected_fg(state)
  local group = vim.api.nvim_get_hl(0, { name = SEVERITY_HL[state], link = false })
  if type(group.fg) == "number" then
    return ("#%06x"):format(group.fg)
  end
  return FALLBACK_FG[state]
end

-- The color assertions only discriminate if the three groups really differ.
assert(
  expected_fg("blocked") ~= expected_fg("working")
    and expected_fg("working") ~= expected_fg("ok")
    and expected_fg("blocked") ~= expected_fg("ok"),
  "the three severity colors are distinct in this colorscheme"
)

local function has(text, needle)
  -- Plain find: the icons are multibyte and format templates contain braces.
  return text:find(needle, 1, true) ~= nil
end

local function assert_clean(text, label)
  assert(not has(text, "  "), label .. " has no double space: " .. ("%q"):format(text))
  assert(text == vim.trim(text), label .. " has no leading/trailing space: " .. ("%q"):format(text))
end

--- refresh() coalesces onto an in-flight request, so waits re-issue it rather
--- than riding a poll that may have been spawned under the previous config.
local function wait_for_total(total)
  return vim.wait(5000, function()
    if agents.counts().total == total then
      return true
    end
    agents.refresh()
    return false
  end, 100)
end

-- 2. Real config, no data yet: hide_when_zero collapses every token away.
require("herdr").setup({
  cmd = "herdr-stub",
  agents = { auto_start = false, poll_interval_ms = 100 },
})
assert(not agents.is_polling(), "auto_start = false leaves polling off")
assert(ll.component_text() == "", "all-zero counts render nothing when hide_when_zero")
assert(comp.cond() == false, "cond() is false with nothing to show")

-- 3. herdr-stub: 1 working, 1 blocked, 1 done.
agents.start()
assert(wait_for_total(3), "stub data reaches the agents cache")
local counts = agents.counts()
assert(counts.working == 1 and counts.blocked == 1 and counts.done == 1, "stub counts: " .. vim.inspect(counts))

local text = ll.component_text()
assert(text ~= "", "component_text() renders with data: " .. text)
for _, state in ipairs({ "working", "blocked", "done" }) do
  assert(has(text, ICONS[state]), ("default format shows the %s icon: %s"):format(state, text))
  assert(has(text, ICONS[state] .. " 1"), ("%s renders icon + count: %s"):format(state, text))
end
-- The default format carries {idle}, but every stub agent is busy, so
-- hide_when_zero drops the token rather than printing "○ 0".
assert(not has(text, ICONS.idle), "a zero idle count drops out of the default format: " .. text)
assert_clean(text, "default format")
assert(comp.cond() == true, "cond() is true while polling with agents present")
assert(comp[1]() == text, "the component function returns component_text()")

-- 4. Format tokens are honored, and dropped tokens leave no whitespace scars.
config.setup({ cmd = "herdr-stub", lualine = { format = "{blocked}" } })
local blocked_only = ll.component_text()
assert(blocked_only == ICONS.blocked .. " 1", "{blocked} renders only the blocked section: " .. blocked_only)
assert(not has(blocked_only, ICONS.working), "{blocked} omits the working icon")

config.setup({ cmd = "herdr-stub", lualine = { format = "{total} agents" } })
local total_text = ll.component_text()
assert(total_text == "3 agents", "{total} renders the bare tally (no icon exists for it): " .. total_text)

config.setup({ cmd = "herdr-stub", lualine = { format = "{working} {blocked} {done} {idle}" } })
local with_idle = ll.component_text()
assert(not has(with_idle, ICONS.idle), "a zero {idle} token disappears: " .. with_idle)
assert_clean(with_idle, "template with a dropped trailing token")

config.setup({ cmd = "herdr-stub", lualine = { format = "{bogus} {total}" } })
local bogus = ll.component_text()
assert(bogus == "3", "an unknown token expands to nothing: " .. ("%q"):format(bogus))

-- 5. Color: blocked outranks working.
config.setup({ cmd = "herdr-stub", agents = { auto_start = false, poll_interval_ms = 100 } })
local blocked_color = comp.color()
assert(
  blocked_color.fg == expected_fg("blocked"),
  ("blocked > 0 uses the DiagnosticError fg: %s vs %s"):format(blocked_color.fg, expected_fg("blocked"))
)

-- 6. herdr-stub-v2: a single working agent named "solo". hide_when_zero hides
-- the states that dropped to zero, and the color falls back to the warn path.
config.setup({ cmd = "herdr-stub-v2", agents = { auto_start = false, poll_interval_ms = 100 } })
assert(wait_for_total(1), "herdr-stub-v2 data reaches the cache")
local solo = ll.component_text()
assert(has(solo, ICONS.working .. " 1"), "the working section survives: " .. solo)
assert(not has(solo, ICONS.blocked), "hide_when_zero drops the blocked icon: " .. solo)
assert(not has(solo, ICONS.done), "hide_when_zero drops the done icon: " .. solo)
assert(not has(solo, "0"), "hide_when_zero prints no zeros: " .. solo)
assert_clean(solo, "hide_when_zero text")
assert(comp.cond() == true, "cond() is true with one working agent")

local working_color = comp.color()
assert(
  working_color.fg == expected_fg("working"),
  ("working > 0 (blocked == 0) uses the DiagnosticWarn fg: %s"):format(working_color.fg)
)
assert(working_color.fg ~= blocked_color.fg, "the working color differs from the blocked color")

-- 7. hide_when_zero = false: the zeros come back.
config.setup({
  cmd = "herdr-stub-v2",
  lualine = { hide_when_zero = false },
  agents = { auto_start = false, poll_interval_ms = 100 },
})
local with_zeros = ll.component_text()
assert(has(with_zeros, ICONS.blocked .. " 0"), "hide_when_zero = false shows blocked 0: " .. with_zeros)
assert(has(with_zeros, ICONS.done .. " 0"), "hide_when_zero = false shows done 0: " .. with_zeros)
assert(has(with_zeros, ICONS.working .. " 1"), "hide_when_zero = false still shows the real count")
assert_clean(with_zeros, "hide_when_zero = false text")

-- 8. The "nothing running" case, driven through agents.counts() so it does not
-- depend on a stub that returns an empty list. The module looks the function up
-- on the module table at call time, so this seam is exactly what it reads.
local real_counts = agents.counts
agents.counts = function()
  return { working = 0, blocked = 0, done = 0, idle = 0, unknown = 0, total = 0 }
end

local zero_text = ll.component_text()
assert(zero_text ~= "", "hide_when_zero = false renders even with zero counts: " .. zero_text)
assert_clean(zero_text, "all-zero text")
-- show_when_idle (module-local fallback: false, config.lua has no such key yet)
-- keeps the segment off the statusline when herdr knows about no agents at all.
assert(comp.cond() == false, "cond() is false with zero agents (show_when_idle fallback)")
assert(comp.color().fg == expected_fg("ok"), "no blocked and no working uses the DiagnosticOk fg")

config.setup({ cmd = "herdr-stub-v2", agents = { auto_start = false, poll_interval_ms = 100 } })
assert(ll.component_text() == "", "hide_when_zero back on: zero counts render nothing")
assert(comp.cond() == false, "cond() is false when the text is empty")

-- The default format must be able to express an entirely idle fleet. One real
-- idle agent used to render "" and hide the component while the agents float
-- listed it; the {idle} token in the default format is what fixes that, and
-- hide_when_zero is back on here so the token is doing the work on its own.
agents.counts = function()
  return { working = 0, blocked = 0, done = 0, idle = 1, unknown = 0, total = 1 }
end
local idle_only = ll.component_text()
assert(
  idle_only == ICONS.idle .. " 1",
  "an idle-only fleet renders the idle token: " .. ("%q"):format(idle_only)
)
assert(comp.cond() == true, "an idle-only fleet keeps the component visible")
agents.counts = real_counts

-- 9. Cleared Diagnostic groups must not break a redraw; the hardcoded per-state
-- fallback answers instead. All three are cleared at once because color() only
-- reads the group for the state that currently wins.
local saved_hl = {}
for _, group in pairs(SEVERITY_HL) do
  saved_hl[group] = vim.api.nvim_get_hl(0, { name = group })
  vim.api.nvim_set_hl(0, group, {})
end

local CLEARED_CASES = {
  -- current cache is one working agent
  { counts = nil, state = "working" },
  { counts = { working = 1, blocked = 1, done = 0, idle = 0, unknown = 0, total = 2 }, state = "blocked" },
  { counts = { working = 0, blocked = 0, done = 1, idle = 0, unknown = 0, total = 1 }, state = "ok" },
}
for _, case in ipairs(CLEARED_CASES) do
  if case.counts then
    agents.counts = function()
      return vim.deepcopy(case.counts)
    end
  end
  local ok, value = pcall(comp.color)
  assert(ok, "color() survives cleared Diagnostic groups (" .. case.state .. ")")
  assert(
    type(value.fg) == "string" and value.fg:match("^#%x%x%x%x%x%x$"),
    ("cleared groups still yield a hex fg: %s"):format(tostring(value.fg))
  )
  assert(
    value.fg == FALLBACK_FG[case.state],
    ("%s falls back to its documented hex: %s"):format(case.state, value.fg)
  )
  agents.counts = real_counts
end

for group, def in pairs(saved_hl) do
  assert(pcall(vim.api.nvim_set_hl, 0, group, def), "restored " .. group)
end
assert(comp.color().fg == expected_fg("working"), "colors resolve from the groups again after restore")

-- 10. A garbage lualine table must not throw either: lualine calls these on
-- every redraw, so a bad user config degrades to the defaults, never to an
-- error inside the statusline.
config.options.lualine = { format = 42, icons = "not a table", hide_when_zero = true }
local ok_garbage, garbage = pcall(ll.component_text)
assert(ok_garbage and type(garbage) == "string", "component_text() tolerates a broken lualine table")
assert(pcall(comp.cond), "cond() tolerates a broken lualine table")
assert(pcall(comp.color), "color() tolerates a broken lualine table")

-- 11. Degraded: polling gave up, so the counts on screen are frozen. The
-- component stays VISIBLE - degrading is the moment the user most needs to know
-- - carries a marker so the frozen counts cannot pass for live ones, and borrows
-- the error color. is_degraded() implies not is_polling() (degrading is what
-- stops the timer), so cond() must not key off is_polling() alone.
agents.stop()
config.setup({
  cmd = "herdr-stub-fail",
  agents = { auto_start = false, poll_interval_ms = 50, max_failures = 1 },
})
agents.start()
assert(vim.wait(5000, function()
  return agents.is_degraded()
end, 20), "the failing stub degrades polling")
assert(not agents.is_polling(), "degradation stopped the timer")

local ok_degraded, degraded_color = pcall(comp.color)
assert(ok_degraded, "color() does not throw while degraded")
assert(
  degraded_color.fg == expected_fg("blocked"),
  ("degraded borrows the DiagnosticError fg: %s"):format(degraded_color.fg)
)
assert(comp.cond() == true, "cond() is TRUE while degraded: the segment must not vanish")

local ok_text, degraded_text = pcall(ll.component_text)
assert(ok_text, "component_text() does not throw while degraded")
assert(degraded_text ~= "", "degraded text is never empty (cond() is true)")
assert(has(degraded_text, "!"), "degraded text carries the trouble marker: " .. degraded_text)
-- The cache survives a failure, so the frozen counts are still rendered beside
-- the marker rather than replaced by it.
assert(
  has(degraded_text, ICONS.working .. " 1"),
  "degraded text keeps the last known counts: " .. degraded_text
)
assert_clean(degraded_text, "degraded text")

-- Nothing cached to freeze: the marker alone still has to say something, or the
-- empty string would hide the component exactly when polling has given up.
local degraded_zero = agents.counts
agents.counts = function()
  return { working = 0, blocked = 0, done = 0, idle = 0, unknown = 0, total = 0 }
end
local stopped_text = ll.component_text()
assert(stopped_text ~= "", "degraded with zero counts still renders something")
assert(has(stopped_text, "herdr"), "degraded-and-empty names the plugin: " .. stopped_text)
assert(comp.cond() == true, "cond() is true while degraded even with zero counts")
agents.counts = degraded_zero

-- A successful poll clears the degraded state, so the marker goes away.
config.setup({ cmd = "herdr-stub-v2", agents = { auto_start = false, poll_interval_ms = 100 } })
agents.start()
assert(vim.wait(5000, function()
  return not agents.is_degraded() and agents.counts().total == 1
end, 20), "recovery clears the degraded flag")
assert(not has(ll.component_text(), "!"), "the marker is gone once polling recovers")
agents.stop()

-- 12. Explicit stop hides the component too.
config.setup({ cmd = "herdr-stub-v2", agents = { auto_start = false, poll_interval_ms = 100 } })
agents.start()
assert(agents.is_polling(), "start() re-arms polling")
assert(wait_for_total(1), "data lands again after the restart")
assert(comp.cond() == true, "cond() is true again once polling resumes")
agents.stop()
assert(comp.cond() == false, "cond() is false after agents.stop()")

-- Cleanup: a leaked timer or listener would hang the headless exit.
agents.cleanup()
assert(not agents.is_polling(), "no polling left at test end")

vim.notify = original_notify
print("PASS: F010 lualine component shape, format tokens, hide_when_zero and severity color")
