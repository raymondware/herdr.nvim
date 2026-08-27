-- F015: the agents float grouped by workspace - grouping, label resolution,
-- ordering determinism, the degraded-label fallbacks, and the row map that <CR>
-- resolves against (the class of bug a previous QA pass flagged).
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F015_test.lua" -c "qa!"
--
-- The invariants:
--   1. Every agent herdr reports is rendered, in exactly one group, whatever the
--      workspace lookup did or did not manage to say. Labels are decoration; the
--      agent rows are the data.
--   2. The row map stays exact. The global header, a workspace header, a blank
--      separator, the degraded notice and the empty-state line are NOT selectable,
--      and every agent row resolves to its own agent - across a re-render that
--      regroups, and with the degraded notice shifting every row down.
--   3. Two polls that returned the same fleet render byte-identically, so the
--      view does not jitter under the reader's cursor. table.sort is not stable,
--      so this is a property of the comparators being total orders.
--   4. cli.workspace_list invokes its callback EXACTLY once for any subprocess
--      output whatsoever, the same contract cli.lua documents for agent list/get.
--
-- tests/fixtures/herdr-stub-multi is built so one `agent list` reaches every
-- branch: labelled workspaces, a DUPLICATE label only an id can disambiguate, a
-- workspace absent from `workspace list` (raw id plus a derived rollup), and an
-- agent with no workspace_id at all.

local agents = require("herdr.agents")
local cli = require("herdr.cli")
local config = require("herdr.config")
local hl = require("herdr.hl")
local ui = require("herdr.agents_ui")
local helpers = dofile(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua"
)

-- Degradation warns on purpose; keep headless output to the PASS lines.
local original_notify = vim.notify
vim.notify = function() end

-- Leak instrumentation, the same seam F009/F011 use: agents_ui looks up
-- on_update on the module table at call time.
local real_on_update = agents.on_update
local subs, unsubs = 0, 0
agents.on_update = function(fn)
  subs = subs + 1
  local unsubscribe = real_on_update(fn)
  return function()
    unsubs = unsubs + 1
    unsubscribe()
  end
end

local MULTI_TOTAL = 7
local MULTI_NAMES = {
  "claude-1",
  "reviewer",
  "codex",
  "dup-1",
  "ghost-done",
  "ghost-blocked",
  "orphan",
}

---@return integer
local function current_buf()
  return vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
end

---@param buf integer
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param buf integer
---@return string
local function text(buf)
  return table.concat(lines(buf), "\n")
end

--- 1-based buffer line containing `needle` (plain find), or nil.
---@param buf integer
---@param needle string
---@return integer|nil
local function row_of(buf, needle)
  for i, line in ipairs(lines(buf)) do
    if line:find(needle, 1, true) then
      return i
    end
  end
end

---@param buf integer
---@param needle string
---@return integer
local function require_row(buf, needle)
  local row = row_of(buf, needle)
  assert(row, ("no line containing %q in:\n%s"):format(needle, text(buf)))
  return row
end

--- Every workspace header line, in render order. A header is the only line that
--- starts with exactly one space: agent rows are indented three, the global header
--- and the degraded notice start in column 0, separators are empty.
---@param buf integer
---@return table[] {row, line}
local function group_headers(buf)
  local found = {}
  for i, line in ipairs(lines(buf)) do
    if line:match("^ %S") then
      found[#found + 1] = { row = i, line = line }
    end
  end
  return found
end

---@param buf integer
---@return table<string, table>
local function keymap_lhs(buf)
  local found = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    found[map.lhs] = map
  end
  return found
end

--- Window title as plain text (nvim returns it as {text, hl} chunks).
---@param win integer
---@return string
local function title_text(win)
  local title = vim.api.nvim_win_get_config(win).title
  if type(title) == "string" then
    return title
  end
  local parts = {}
  for _, chunk in ipairs(title or {}) do
    parts[#parts + 1] = chunk[1]
  end
  return table.concat(parts)
end

--- Extmark highlight groups on one 0-based row.
---@param buf integer
---@param row integer 0-based
---@return table<string, boolean>
local function row_groups(buf, row)
  local found = {}
  local marks =
    vim.api.nvim_buf_get_extmarks(buf, hl.ns, { row, 0 }, { row, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details and details.hl_group then
      found[details.hl_group] = true
    end
  end
  return found
end

--- Point the poller at `cmd` and wait until its agent list is cached. refresh()
--- is re-issued because it coalesces onto an in-flight request rather than
--- spawning a second one.
---@param cmd string
---@param total integer expected agent count
local function seed(cmd, total)
  config.setup({ cmd = cmd, agents = { auto_start = false, poll_interval_ms = 100 } })
  assert(vim.wait(8000, function()
    if agents.counts().total == total then
      return true
    end
    agents.refresh()
    return false
  end, 100), ("%s data reaches the agents cache"):format(cmd))
end

-- ===========================================================================
-- 1. PURE parse_workspace_list / normalize_workspace.
--
-- Same discipline as parse_agent_list: nothing here throws for any input, an
-- object where an array belongs is an error rather than a silent empty list,
-- unusable entries are skipped, and a state outside the documented enum clamps.
-- ===========================================================================
local ENVELOPE = table.concat({
  '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[',
  '{"active_tab_id":"wA:t1","agent_status":"blocked","focused":true,"label":"rware",',
  '"number":2,"pane_count":3,"tab_count":2,"workspace_id":"wA"}]}}',
})
local parsed = assert(cli.parse_workspace_list(ENVELOPE), "a real envelope parses")
assert(#parsed == 1, "one workspace parsed, got " .. #parsed)
assert(parsed[1].workspace_id == "wA", "workspace_id normalized")
assert(parsed[1].label == "rware", "label normalized")
assert(parsed[1].number == 2, "number normalized")
assert(parsed[1].focused == true, "focused normalized")
assert(parsed[1].state == "blocked", "agent_status normalized to state")
assert(parsed[1].tab_count == 2 and parsed[1].pane_count == 3, "counts normalized")

local empty = assert(
  cli.parse_workspace_list('{"id":"x","result":{"type":"workspace_list","workspaces":[]}}'),
  "an empty list is a success, not an error"
)
assert(#empty == 0, "an empty list has no entries")

-- Malformed, missing and wrong-shaped envelopes are errors, never throws.
for _, case in ipairs({
  { label = "malformed JSON", stdout = '{"result":{"workspaces":[' },
  { label = "not JSON at all", stdout = "Error: Os { code: 2 }" },
  { label = "empty stdout", stdout = "" },
  { label = "no result", stdout = '{"id":"x"}' },
  { label = "no workspaces key", stdout = '{"id":"x","result":{"type":"workspace_list"}}' },
  { label = "workspaces is a string", stdout = '{"id":"x","result":{"workspaces":"nope"}}' },
  {
    label = "workspaces is an object",
    stdout = '{"id":"x","result":{"workspaces":{"wA":{"workspace_id":"wA"}}}}',
  },
  -- A JSON null inside the array leaves a HOLE once luanil is applied, and a
  -- table with a hole is not a list: reported as an error rather than silently
  -- truncating the fleet at the hole (same behavior as result.agents).
  {
    label = "null entry in the array",
    stdout = '{"id":"x","result":{"workspaces":[null,{"workspace_id":"wA"}]}}',
  },
}) do
  local ok, result, err = pcall(cli.parse_workspace_list, case.stdout)
  assert(ok, case.label .. ": parser does not throw: " .. tostring(result))
  assert(result == nil, case.label .. ": no workspaces returned")
  assert(type(err) == "string" and err ~= "", case.label .. ": an error string is returned")
end

-- Non-table entries and entries with no usable id are SKIPPED, not synthesized:
-- the only thing a workspace record is for is answering "what is <id> called".
local mixed = assert(cli.parse_workspace_list(table.concat({
  '{"id":"x","result":{"workspaces":[',
  '"scalar",',
  "42,",
  '{"label":"no id"},',
  '{"workspace_id":"","label":"blank id"},',
  '{"workspace_id":"wB","label":"kept","agent_status":"exploded"},',
  '{"workspace_id":"wC","label":123,"number":"7"}',
  "]}}",
})))
assert(#mixed == 2, "only the two keyable entries survived, got " .. #mixed)
assert(mixed[1].workspace_id == "wB" and mixed[1].label == "kept", "the good entry is intact")
assert(mixed[1].state == "unknown", "a state outside the enum clamps to unknown")
assert(mixed[2].workspace_id == "wC", "an entry with a junk label is still keyable")
assert(mixed[2].label == nil, "a non-string label is dropped rather than coerced")
assert(mixed[2].number == 7, "a stringly-typed number is coerced: " .. tostring(mixed[2].number))

assert(cli.normalize_workspace(nil) == nil, "normalize_workspace(nil) is nil")
assert(cli.normalize_workspace("wA") == nil, "normalize_workspace of a scalar is nil")
assert(cli.normalize_workspace({}) == nil, "normalize_workspace with no id is nil")

-- cli.spawn_key is the ONE definition of request identity that agents.lua's poll
-- and agents_ui.lua's workspace cache both compare against.
config.setup({ cmd = "herdr-stub-multi" })
local key_plain = cli.spawn_key()
config.setup({ cmd = "herdr-stub-multi", session = "f015-probe" })
assert(cli.spawn_key() ~= key_plain, "the session is part of the spawn key")
config.setup({ cmd = "herdr-stub" })
assert(cli.spawn_key() ~= key_plain, "the cmd is part of the spawn key")

print("PASS: F015 (1/8) parse_workspace_list is pure, defensive and enum-clamped")

-- ===========================================================================
-- 2. cli.workspace_list: cb EXACTLY once for any subprocess output whatsoever.
-- The parsing runs inside a vim.system callback, where a throw does not reach the
-- caller - it is reported by the scheduler and the callback is simply lost.
-- ===========================================================================
local scratch = vim.fn.tempname()
assert(vim.fn.mkdir(scratch, "p") == 1, "scratch dir for the throwaway stubs")
vim.env.PATH = scratch .. ":" .. vim.env.PATH

---@param name string
---@param body string[] shell script lines after the shebang
---@return string cmd name
local function stub(name, body)
  local path = scratch .. "/" .. name
  local script = { "#!/bin/sh" }
  vim.list_extend(script, body)
  assert(vim.fn.writefile(script, path) == 0, "wrote " .. name)
  vim.fn.setfperm(path, "rwxr-xr-x")
  assert(vim.fn.executable(name) == 1, name .. " is executable on $PATH")
  return name
end

local GOOD_WS =
  [[{"id":"x","result":{"type":"workspace_list","workspaces":[{"workspace_id":"wZ","label":"z","number":1,"agent_status":"idle"}]}}]]
local SERVER_DOWN_LINE =
  [[Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }]]
local ERROR_ENVELOPE =
  [[{"error":{"code":"bad","message":"workspace lookup failed"},"id":"cli:workspace:list"}]]

local ONCE_CASES = {
  {
    label = "valid envelope",
    body = { ("printf '%%s\\n' '%s'"):format(GOOD_WS) },
    expect_list = 1,
  },
  { label = "empty stdout, exit 0", body = { "exit 0" } },
  { label = "garbage on stdout", body = { "echo not-json", "exit 0" } },
  {
    label = "truncated JSON",
    body = { "printf '%s' '{\"result\":{\"workspaces\":['", "exit 0" },
  },
  {
    label = "server down",
    body = { ("echo '%s' >&2"):format(SERVER_DOWN_LINE), "exit 1" },
  },
  {
    label = "error envelope on stderr",
    body = { ("printf '%%s\\n' '%s' >&2"):format(ERROR_ENVELOPE), "exit 1" },
  },
  { label = "exit 2 with nothing at all", body = { "exit 2" } },
  {
    label = "entries that all get skipped",
    body = { [[printf '%s\n' '{"id":"x","result":{"workspaces":["a",1]}}']] },
    expect_list = 0,
  },
}

for i, case in ipairs(ONCE_CASES) do
  local cmd = stub(("f015-ws-%d"):format(i), case.body)
  config.setup({ cmd = cmd, agents = { auto_start = false } })
  local calls, got_list, got_err = 0, nil, nil
  cli.workspace_list(function(list, err)
    calls = calls + 1
    got_list, got_err = list, err
  end)
  assert(vim.wait(8000, function()
    return calls > 0
  end, 10), case.label .. ": the callback ran")
  -- Room for a second, wrong delivery to show up.
  vim.wait(80)
  assert(calls == 1, ("%s: cb fired exactly once, got %d"):format(case.label, calls))
  if case.expect_list then
    assert(
      type(got_list) == "table" and #got_list == case.expect_list,
      ("%s: %d workspaces, got %s"):format(case.label, case.expect_list, vim.inspect(got_list))
    )
    assert(got_err == nil, case.label .. ": no error alongside a good list")
  else
    assert(got_list == nil, case.label .. ": no workspaces returned")
    assert(type(got_err) == "string" and got_err ~= "", case.label .. ": a usable error string")
  end
end

-- A missing binary is an error too, delivered once and never inline.
config.setup({ cmd = "f015-no-such-binary-zzz", agents = { auto_start = false } })
local missing_calls, missing_err = 0, nil
cli.workspace_list(function(list, err)
  missing_calls = missing_calls + 1
  missing_err = err
  assert(list == nil, "a missing binary returns no workspaces")
end)
assert(missing_calls == 0, "cb is never invoked inline, even for a missing binary")
assert(vim.wait(8000, function()
  return missing_calls > 0
end, 10), "the missing-binary callback ran")
vim.wait(60)
assert(missing_calls == 1, "the missing-binary callback ran once, got " .. missing_calls)
assert(missing_err and missing_err:find("not found", 1, true), "it names the missing binary")

print("PASS: F015 (2/8) cli.workspace_list delivers its callback exactly once")

-- ===========================================================================
-- 3. Grouping and label resolution against the multi-workspace fixture.
-- ===========================================================================
seed("herdr-stub-multi", MULTI_TOTAL)
ui.open()
local win = vim.api.nvim_get_current_win()
local buf = current_buf()
assert(vim.wait(8000, function()
  return text(buf):find("api-refactor (w7)", 1, true) ~= nil
end, 20), "the workspace lookup labelled the group headers:\n" .. text(buf))
-- Freeze the frame: open() armed the timer, and the assertions below are about
-- one rendered frame, not about a moving one.
agents.stop()
vim.wait(200)

local frame = lines(buf)
-- The global header line is untouched by grouping (F009 asserts it too).
assert(
  frame[1]:match("^7 agents%s+2 working%s+2 blocked%s+2 done%s+1 idle$"),
  "the global header line is unchanged: " .. frame[1]
)
assert(frame[2] == "", "the separator under the global header survives")

-- Ordering: by workspace `number` (the fixture numbers w7=1, w9=2, w5=3, which
-- deliberately disagrees with id order), then the workspace with no number, then
-- the bucket.
local headers = group_headers(buf)
local titles = vim.tbl_map(function(entry)
  return entry.line
end, headers)
assert(#titles == 5, "five group headers, got " .. vim.inspect(titles))
assert(titles[1]:match("^ api%-refactor %(w7%)"), "w7 (number 1) first: " .. titles[1])
assert(titles[2]:match("^ rware %(w9%)"), "w9 (number 2) second: " .. titles[2])
assert(titles[3]:match("^ rware %(w5%)"), "w5 (number 3) third: " .. titles[3])
assert(titles[4]:match("^ w11%s"), "the unnumbered workspace comes after: " .. titles[4])
assert(titles[5]:find("(unknown workspace)", 1, true), "the bucket is last: " .. titles[5])

-- Duplicate labels are only distinguishable by their id, which is exactly why the
-- id is always rendered next to the label.
assert(titles[2] ~= titles[3], "two workspaces labelled 'rware' render differently")
assert(
  titles[2]:find("(w9)", 1, true) and titles[3]:find("(w5)", 1, true),
  "each duplicate label carries its own workspace id"
)

-- A workspace absent from `workspace list` degrades to its raw id, and its
-- rolled-up state is DERIVED from its rows: blocked (ghost-blocked) beats done
-- (ghost-done).
assert(not titles[4]:find("(", 1, true), "an unknown workspace shows no label: " .. titles[4])
assert(
  titles[4]:find("blocked", 1, true),
  "the derived rollup takes the worst state in the group: " .. titles[4]
)

-- The other rollups come straight from `workspace list`.
assert(titles[1]:find("working", 1, true), "w7 header shows its reported state")
assert(titles[2]:find("done", 1, true), "w9 header shows its reported state")
assert(titles[3]:find("blocked", 1, true), "w5 header shows its reported state")

-- Every agent is rendered exactly once, and nothing was dropped.
for _, name in ipairs(MULTI_NAMES) do
  local seen = 0
  for _, line in ipairs(frame) do
    if line:find(name, 1, true) then
      seen = seen + 1
    end
  end
  assert(seen == 1, ("%s is rendered exactly once, got %d"):format(name, seen))
end
assert(
  require_row(buf, "orphan") > headers[5].row,
  "an agent with no workspace_id lands in the (unknown workspace) bucket"
)

-- Agent rows are indented under their header and carry the SHORTENED location:
-- the fixture's ids are hierarchical (w5:t1, w5:p2), so the redundant workspace
-- prefix is gone.
local claude_row = require_row(buf, "claude-1")
assert(frame[claude_row]:match("^   "), "agent rows are indented: " .. frame[claude_row])
assert(
  frame[claude_row]:find(" t1:p2", 1, true),
  "the location drops the workspace prefix: " .. frame[claude_row]
)
assert(
  not frame[claude_row]:find("w5:", 1, true),
  "the workspace id is not repeated on the row: " .. frame[claude_row]
)
assert(
  frame[claude_row]:find("/tmp/five", 1, true),
  "the existing cwd detail is kept: " .. frame[claude_row]
)
-- The pane-id fallback is gone from the detail cell now that the location column
-- shows it; the orphan has no cwd and no terminal title, so it falls back to kind.
local orphan_row = require_row(buf, "orphan")
assert(frame[orphan_row]:find(" p99", 1, true), "an agent with no tab shows its pane alone")
assert(frame[orphan_row]:find("claude", 1, true), "the kind is still the last detail fallback")

-- Worst state first inside a group, then name: w5 lists blocked claude-1 above
-- working reviewer, and w11 lists ghost-blocked above ghost-done.
assert(
  require_row(buf, "claude-1") < require_row(buf, "reviewer"),
  "blocked sorts above working inside a workspace"
)
assert(
  require_row(buf, "ghost-blocked") < require_row(buf, "ghost-done"),
  "the derived-rollup group is sorted the same way"
)

-- Highlighting: the title with HerdrHeader, the rollup badge with its state group.
local w5_marks = row_groups(buf, headers[3].row - 1)
assert(w5_marks.HerdrHeader, "the workspace label is highlighted as a header")
assert(w5_marks.HerdrAgentBlocked, "the blocked rollup badge uses the blocked group")
local w7_marks = row_groups(buf, headers[1].row - 1)
assert(w7_marks.HerdrHeader and w7_marks.HerdrAgentWorking, "a working rollup uses its own group")
local bucket_marks = row_groups(buf, headers[5].row - 1)
assert(bucket_marks.HerdrHeader, "the bucket header is a header too")
assert(bucket_marks.HerdrAgentIdle, "an idle rollup falls back to the idle group")

print("PASS: F015 (3/8) grouping, ordering, labels, shortened locations and rollups")

-- ===========================================================================
-- 4. Invariant 2: the row map. Workspace headers, blank separators and the global
-- header are not selectable; every agent row resolves to its own agent.
-- ===========================================================================
local maps = keymap_lhs(buf)
assert(maps["<CR>"], "<CR> is mapped in the grouped float")

---@param row integer 1-based
---@param what string
local function assert_no_op(row, what)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  assert(pcall(maps["<CR>"].callback), what .. ": <CR> does not throw")
  assert(not ui.detail_is_open(), ("%s (line %d) opened a detail float"):format(what, row))
end

assert_no_op(1, "the global header")
assert_no_op(2, "the separator under the global header")
for i, entry in ipairs(headers) do
  assert_no_op(entry.row, "workspace header " .. i)
  if i > 1 then
    -- Every group but the first is preceded by a blank separator.
    assert(frame[entry.row - 1] == "", "a blank separator precedes group " .. i)
    assert_no_op(entry.row - 1, "the blank separator before group " .. i)
  end
end

---@param name string agent whose row the cursor goes to
local function assert_opens(name)
  vim.api.nvim_win_set_cursor(win, { require_row(buf, name), 0 })
  maps["<CR>"].callback()
  assert(ui.detail_is_open(), name .. ": <CR> opened the detail float")
  local title = title_text(vim.api.nvim_get_current_win())
  assert(title:find(name, 1, true), ("<CR> targeted %s, got title %q"):format(name, title))
  ui.detail_close()
  assert(not ui.detail_is_open(), name .. ": the detail float closed again")
end

for _, name in ipairs(MULTI_NAMES) do
  assert_opens(name)
end

print("PASS: F015 (4/8) <CR> no-ops on headers and separators, resolves every agent row")

-- ===========================================================================
-- 5. Invariant 3: two identical polls render byte-identically.
-- ===========================================================================
local first_frame = table.concat(lines(buf), "\n")
local polls = 0
local unsub_polls = real_on_update(function()
  polls = polls + 1
end)
agents.refresh()
assert(vim.wait(8000, function()
  return polls >= 1
end, 20), "a second poll of the same fixture landed")
-- The workspace lookup that follows the poll repaints once more; let it settle.
vim.wait(300)
local second_frame = table.concat(lines(buf), "\n")
assert(
  first_frame == second_frame,
  ("two identical polls rendered differently:\n--- first ---\n%s\n--- second ---\n%s"):format(
    first_frame,
    second_frame
  )
)
unsub_polls()

print("PASS: F015 (5/8) ordering is deterministic across identical polls")

-- ===========================================================================
-- 6. Invariant 2 under a re-render that CHANGES the grouping, and again with the
-- degraded notice present. Both shift every row: the row map has to be rebuilt
-- correctly and the cursor has to travel with the agent it was on.
-- ===========================================================================
-- herdr-stub is a single workspace (w1) with three agents, so the whole grouping
-- is replaced in place.
vim.api.nvim_win_set_cursor(win, { require_row(buf, "reviewer"), 0 })
config.setup({ cmd = "herdr-stub", agents = { auto_start = false, poll_interval_ms = 100 } })
agents.refresh()
assert(vim.wait(8000, function()
  return row_of(buf, "claude-1") ~= nil and row_of(buf, "ghost-done") == nil
end, 20), "the regrouped frame replaced the multi-workspace one:\n" .. text(buf))
vim.wait(200)
-- The labels described the OTHER server, so they are dropped: the cache is keyed
-- by cli.spawn_key().
assert(
  not text(buf):find("api-refactor", 1, true),
  "labels from a superseded cmd are dropped:\n" .. text(buf)
)
assert(#group_headers(buf) == 1, "one workspace in the new frame:\n" .. text(buf))
assert(row_of(buf, " w1"), "the new frame groups under w1:\n" .. text(buf))
-- reviewer exists in herdr-stub too, so the cursor should have followed it.
assert(
  vim.api.nvim_win_get_cursor(win)[1] == require_row(buf, "reviewer"),
  "the cursor followed the agent across the regrouping"
)
maps = keymap_lhs(buf)
for _, name in ipairs({ "claude-1", "codex", "reviewer" }) do
  vim.api.nvim_win_set_cursor(win, { require_row(buf, name), 0 })
  maps["<CR>"].callback()
  assert(ui.detail_is_open(), name .. ": <CR> works after the regrouping")
  assert(
    title_text(vim.api.nvim_get_current_win()):find(name, 1, true),
    "the regrouped row map is exact: expected " .. name
  )
  ui.detail_close()
end
vim.api.nvim_win_set_cursor(win, { require_row(buf, " w1"), 0 })
assert(pcall(maps["<CR>"].callback), "<CR> on the regrouped workspace header does not throw")
assert(not ui.detail_is_open(), "<CR> on the regrouped workspace header is a no-op")

-- Now degrade while the float is open: the notice goes in ABOVE everything, so
-- the group header and every row shift down one line.
local before_header = require_row(buf, " w1")
local before_row = require_row(buf, "reviewer")
vim.api.nvim_win_set_cursor(win, { before_row, 0 })
config.setup({
  cmd = "herdr-stub-fail",
  agents = { auto_start = false, poll_interval_ms = 50, max_failures = 1 },
})
agents.start()
assert(vim.wait(8000, function()
  return agents.is_degraded() and row_of(buf, "polling stopped") ~= nil
end, 20), "polling degrades while the grouped float is open")
agents.stop()
vim.wait(200)

assert(require_row(buf, " w1") == before_header + 1, "the notice pushed the group header down")
assert(require_row(buf, "reviewer") == before_row + 1, "the notice pushed the agent rows down")
assert(
  vim.api.nvim_win_get_cursor(win)[1] == require_row(buf, "reviewer"),
  "the cursor followed the agent past the notice"
)
-- The notice line and the shifted workspace header are both no-ops...
for _, needle in ipairs({ "polling stopped", " w1" }) do
  vim.api.nvim_win_set_cursor(win, { require_row(buf, needle), 0 })
  assert(pcall(maps["<CR>"].callback), ("<CR> on the %q line does not throw"):format(needle))
  assert(not ui.detail_is_open(), ("<CR> on the %q line is a no-op"):format(needle))
end
-- ...and every agent row still resolves to itself with the notice in place.
for _, name in ipairs({ "claude-1", "codex", "reviewer" }) do
  vim.api.nvim_win_set_cursor(win, { require_row(buf, name), 0 })
  maps["<CR>"].callback()
  assert(ui.detail_is_open(), name .. ": <CR> works with the degraded notice present")
  assert(
    title_text(vim.api.nvim_get_current_win()):find(name, 1, true),
    "the row map is exact with the notice shifting rows: expected " .. name
  )
  ui.detail_close()
end

print("PASS: F015 (6/8) the row map survives regrouping and the degraded notice")

-- ===========================================================================
-- 7. A failing `workspace list` costs nothing but the labels, and the empty state
-- still renders. Same fixture and the same agents; only the lookup fails.
-- ===========================================================================
ui.close()
agents.stop()
vim.env.HERDR_STUB_WS_FAIL = "1"
seed("herdr-stub-multi", MULTI_TOTAL)
ui.open()
win = vim.api.nvim_get_current_win()
buf = current_buf()
assert(vim.wait(8000, function()
  return row_of(buf, " w5") ~= nil
end, 20), "the raw-id fallback rendered:\n" .. text(buf))
agents.stop()
vim.wait(300)

local fallback = lines(buf)
assert(fallback[1]:match("^7 agents"), "the global header is unaffected: " .. fallback[1])
assert(not text(buf):find("api-refactor", 1, true), "a failed lookup shows no labels:\n" .. text(buf))
assert(
  not text(buf):find("polling stopped", 1, true),
  "a failed workspace lookup adds no notice line of its own"
)
for _, name in ipairs(MULTI_NAMES) do
  assert(row_of(buf, name), name .. " is still listed when the lookup fails:\n" .. text(buf))
end
-- With no reported rollups at all, every header state is derived from its rows.
assert(text(buf):match(" w5%s+%S+ blocked"), "w5 rolls up to blocked from its rows:\n" .. text(buf))
assert(text(buf):match(" w9%s+%S+ done"), "w9 rolls up to done from its row:\n" .. text(buf))
-- Ordering with no numbers to sort by: every workspace falls into the
-- by-workspace-id tier, and the bucket is still last.
local fallback_titles = vim.tbl_map(function(entry)
  return entry.line
end, group_headers(buf))
assert(#fallback_titles == 5, "still five groups: " .. vim.inspect(fallback_titles))
for i, id in ipairs({ " w11", " w5", " w7", " w9" }) do
  assert(
    fallback_titles[i]:sub(1, #id + 1) == id .. " ",
    ("unnumbered workspaces sort by id: slot %d is %q"):format(i, fallback_titles[i])
  )
end
assert(fallback_titles[5]:find("(unknown workspace)", 1, true), "the bucket is still last")
-- And <CR> still resolves rows in a frame with no labels at all.
maps = keymap_lhs(buf)
vim.api.nvim_win_set_cursor(win, { require_row(buf, "dup-1"), 0 })
maps["<CR>"].callback()
assert(ui.detail_is_open(), "<CR> works with no labels resolved")
assert(title_text(vim.api.nvim_get_current_win()):find("dup-1", 1, true), "and targets the row")
ui.detail_close()
vim.env.HERDR_STUB_WS_FAIL = nil
ui.close()

-- The empty state survives grouping: no groups at all, just the placeholder.
local real_get, real_counts = agents.get, agents.counts
agents.get = function()
  return {}
end
agents.counts = function()
  return { working = 0, blocked = 0, done = 0, idle = 0, unknown = 0, total = 0 }
end
ui.open()
agents.stop()
buf = current_buf()
ui.render()
assert(row_of(buf, "No agents"), "the empty state still renders:\n" .. text(buf))
assert(#group_headers(buf) == 0, "no group header for an empty list:\n" .. text(buf))
vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { require_row(buf, "No agents"), 0 })
assert(pcall(keymap_lhs(buf)["<CR>"].callback), "<CR> on the empty-state line does not throw")
assert(not ui.detail_is_open(), "<CR> on the empty-state line is a no-op")
agents.get, agents.counts = real_get, real_counts
ui.close()

print("PASS: F015 (7/8) a failed workspace lookup degrades to raw ids without losing rows")

-- ===========================================================================
-- 8. One check against the REAL herdr binary: the envelope this feature depends
-- on is the one the installed server actually emits. Skipped, loudly, when the
-- server is not running. Read-only either way - `workspace list` never touches
-- the user's workspaces.
-- ===========================================================================
config.setup({ cmd = "herdr", agents = { enabled = false, auto_start = false } })
if not cli.available() then
  print("PASS: F015 (8/8) SKIPPED real-binary check: herdr is not on $PATH")
else
  local real_calls, real_list, real_err = 0, nil, nil
  cli.workspace_list(function(list, err)
    real_calls = real_calls + 1
    real_list, real_err = list, err
  end)
  assert(vim.wait(10000, function()
    return real_calls > 0
  end, 20), "the real herdr answered workspace list")
  vim.wait(80)
  assert(real_calls == 1, "the real binary delivered the callback once, got " .. real_calls)
  if not real_list then
    print("PASS: F015 (8/8) SKIPPED real-binary check: " .. tostring(real_err))
  else
    assert(real_err == nil, "no error alongside a real workspace list: " .. tostring(real_err))
    assert(#real_list >= 1, "the running server reports at least one workspace")
    local labelled = 0
    for _, workspace in ipairs(real_list) do
      assert(
        type(workspace.workspace_id) == "string" and workspace.workspace_id ~= "",
        "every real workspace has an id: " .. vim.inspect(workspace)
      )
      assert(
        type(workspace.state) == "string",
        "every real workspace has a clamped state: " .. vim.inspect(workspace)
      )
      assert(type(workspace.number) == "number", "every real workspace has a number")
      if type(workspace.label) == "string" and workspace.label ~= "" then
        labelled = labelled + 1
      end
    end
    assert(labelled >= 1, "the real server labels its workspaces: " .. vim.inspect(real_list))
    print(("PASS: F015 (8/8) real herdr reported %d workspace(s); first is %s labelled %q"):format(
      #real_list,
      real_list[1].workspace_id,
      tostring(real_list[1].label)
    ))
  end
end

-- ===========================================================================
-- Teardown: no float, no listener, no timer, no live uv handle.
-- ===========================================================================
ui.close()
agents.cleanup()
assert(not ui.is_open() and not ui.detail_is_open(), "no float left at test end")
assert(not agents.is_polling(), "no polling left at test end")
assert(subs == unsubs, "no leaked agents.on_update subscription: " .. subs .. "/" .. unsubs)
helpers.assert_no_live_timers("after cleanup() at F015 end")
vim.fn.delete(scratch, "rf")

agents.on_update = real_on_update
vim.notify = original_notify
print("PASS: F015 agents float grouped by workspace")
