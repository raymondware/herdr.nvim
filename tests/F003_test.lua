-- F003: cli.lua pure envelope parsers, normalization, async run against stubs
-- Run: nvim --headless -u tests/minimal-init.lua -c "luafile tests/F003_test.lua" -c "qa!"
-- (minimal-init puts tests/fixtures on $PATH, so cmd = "herdr-stub" resolves)

local config = require("herdr.config")
local cli = require("herdr.cli")

-- 1. Pure parse of the real 3-agent envelope emitted by the stub fixture
local agents = cli.parse_agent_list(vim.fn.system({ "herdr-stub", "agent", "list" }))
assert(type(agents) == "table", "parse_agent_list returns a table for valid envelope")
assert(#agents == 3, "stub envelope yields 3 agents, got " .. tostring(agents and #agents))

assert(agents[1].name == "claude-1", "agent 1 name from name field")
assert(agents[1].state == "working", "agent 1 state")
assert(agents[2].name == "codex", "agent 2 name falls back name(null) -> display_agent")
assert(agents[2].state == "blocked", "agent 2 state")
assert(agents[3].name == "reviewer", "agent 3 name")
assert(agents[3].state == "done", "agent 3 state")

-- 2. target is pane_id (the value `herdr agent get <target>` addresses);
-- detail keeps the raw AgentInfo
assert(agents[1].target == "p1", "target is pane_id")
assert(agents[1].pane_id == "p1", "pane_id carried through")
assert(agents[1].focused == true, "focused carried through")
assert(agents[1].kind == "claude", "kind is the raw agent field")
assert(type(agents[1].detail) == "table", "detail is the raw AgentInfo table")
assert(agents[1].detail.terminal_id == "t1", "detail.terminal_id preserved")
assert(agents[1].detail.revision == 3, "detail.revision preserved")

-- 3. Malformed JSON -> nil, err (parser is pure, never throws)
local bad, bad_err = cli.parse_agent_list("not json {")
assert(bad == nil, "malformed JSON returns nil")
assert(type(bad_err) == "string", "malformed JSON returns err string")

-- Valid JSON but wrong envelope shape -> nil, err
local shape, shape_err = cli.parse_agent_list('{"id":"x","result":{"type":"other"}}')
assert(shape == nil and type(shape_err) == "string", "missing result.agents -> nil, err")

-- Empty agent list is valid: {} not nil
local empty = cli.parse_agent_list('{"id":"x","result":{"agents":[],"type":"agent_list"}}')
assert(type(empty) == "table" and #empty == 0, "empty agents array parses to empty table")

-- 4. Unknown agent_status clamps to "unknown"; name fallback bottoms out at
-- pane_id when every nullable field is absent
local a2 = cli.parse_agent_list(
  '{"id":"x","result":{"agents":[{"terminal_id":"t9","agent_status":"sleeping",'
    .. '"workspace_id":"w","tab_id":"tb","pane_id":"p9","focused":false,"revision":1}],'
    .. '"type":"agent_list"}}'
)
assert(a2 ~= nil and #a2 == 1, "single-agent envelope parses")
assert(a2[1].state == "unknown", "out-of-enum agent_status normalizes to 'unknown'")
assert(a2[1].name == "p9", "name fallback chain bottoms out at pane_id")

-- 5. Fallback chain order: name -> display_agent -> agent -> title -> pane_id
local via_agent = cli.normalize_agent({
  agent = "claude",
  title = "T",
  agent_status = "idle",
  pane_id = "px",
  focused = false,
})
assert(via_agent.name == "claude", "agent kind wins over title in fallback chain")
local via_title = cli.normalize_agent({
  title = "T",
  agent_status = "idle",
  pane_id = "px",
  focused = false,
})
assert(via_title.name == "T", "title wins over pane_id in fallback chain")

-- 6. parse_agent_get on the stub's agent get envelope
local one, one_err = cli.parse_agent_get(vim.fn.system({ "herdr-stub", "agent", "get", "p1" }))
assert(one ~= nil, "parse_agent_get parses stub envelope: " .. tostring(one_err))
assert(one.name == "claude-1" and one.state == "working" and one.target == "p1", "agent get normalization")
assert(one.detail.cwd == "/tmp/project", "agent get detail preserved")
local get_bad = cli.parse_agent_get("nope{")
assert(get_bad == nil, "parse_agent_get malformed -> nil")

-- 7. available() honors config.options.cmd
config.setup({ cmd = "herdr-stub" })
assert(cli.available() == true, "available() true for stub on $PATH")
config.setup({ cmd = "no-such-bin-xyz" })
assert(cli.available() == false, "available() false for missing binary")

-- 8. run() never throws on a missing binary: cb(nil, err) async
local run_out, run_err
local ran_ok = pcall(cli.run, { "agent", "list" }, function(out, err)
  run_out, run_err = out, err or false
end)
assert(ran_ok, "run() does not throw when binary is missing")
assert(vim.wait(2000, function()
  return run_err ~= nil
end), "missing-binary cb fired")
assert(run_out == nil and type(run_err) == "string", "missing binary -> cb(nil, err)")
assert(run_err:match("not found"), "err mentions binary not found")

-- 9. Async agent_list against the stub
config.setup({ cmd = "herdr-stub" })
local got
cli.agent_list(function(list, err)
  got = list or err
end)
assert(vim.wait(5000, function()
  return got ~= nil
end), "agent_list cb fired")
assert(type(got) == "table", "agent_list delivered agents, got: " .. tostring(got))
assert(#got == 3, "agent_list delivered 3 agents")
assert(got[2].name == "codex" and got[2].state == "blocked", "async result normalized")

-- 10. Async agent_get against the stub
local got_one
cli.agent_get("p1", function(agent, err)
  got_one = agent or err
end)
assert(vim.wait(5000, function()
  return got_one ~= nil
end), "agent_get cb fired")
assert(type(got_one) == "table" and got_one.name == "claude-1", "agent_get normalized result")

-- 11. Server-down error normalization: exit 1 + 'Error: Os {' stderr
config.setup({ cmd = "herdr-stub-fail" })
local gerr
cli.agent_list(function(list, err)
  gerr = err or false
end)
assert(vim.wait(5000, function()
  return gerr ~= nil
end), "failure cb fired")
assert(type(gerr) == "string", "server-down delivers err string")
assert(gerr:lower():match("server"), "err mentions server: " .. tostring(gerr))
assert(gerr:match("not running"), "err says server not running")

print("PASS: F003 cli parsers, normalization, async run, error mapping")
