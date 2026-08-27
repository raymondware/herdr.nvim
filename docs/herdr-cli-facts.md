# herdr CLI facts (verified against herdr 0.7.5 on this machine, 2026-07-23)

Ground truth for cli.lua parsers and test fixtures. Do NOT invent flags; everything below was probed live.

## Binary

- `herdr` at /opt/homebrew/bin/herdr, version output: `herdr 0.7.5` (from `herdr --version`)
- Persistent server; socket at `~/.config/herdr/herdr.sock`
- `herdr` (no args) launches/attaches the TUI client. `herdr --session <name>` for named sessions.
- Detach from TUI: `ctrl+b q`

## Named sessions and the `--session` flag (verified 2026-07-27, herdr 0.7.5)

A named session has its own server and its own socket at
`~/.config/herdr/sessions/<name>/herdr.sock`. The default session is `~/.config/herdr/herdr.sock`.
`herdr session list` shows all of them with their sockets and status.

`--session <name>` is a **global** flag, accepted either **before or after** the subcommand. Both forms
were probed live against a running named session and both route to that session's socket, as confirmed by
the `socket:` line of `herdr status`:

```
$ herdr --session qa-probe status | rg socket
  socket: ~/.config/herdr/sessions/qa-probe/herdr.sock   # leading flag: works
$ herdr status --session qa-probe | rg socket
  socket: ~/.config/herdr/sessions/qa-probe/herdr.sock   # trailing flag: works
$ HERDR_SESSION=qa-probe herdr status | rg socket
  socket: ~/.config/herdr/sessions/qa-probe/herdr.sock   # env var: also works
$ herdr status | rg socket
  socket: ~/.config/herdr/herdr.sock                     # default session
```

Same result for the subcommands the plugin uses, including one with a positional target:

```
$ herdr agent list --session qa-probe
{"id":"cli:agent:list","result":{"agents":[],"type":"agent_list"}}
$ herdr agent get <target> --session qa-probe          # flag after the positional target: works
$ herdr --session qa-probe agent get <target>          # flag before the subcommand: works
$ herdr agent list --session no-such-session-zzz
Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }    # exit 1
```

A missing session is indistinguishable from a stopped server: the same `Error: Os {...}` line and exit 1,
so it normalizes to the same "herdr server not running" message.

**What the plugin does:** `cli.lua` APPENDS `--session <name>` after the subcommand arguments (see
`argv()`), for every call - `agent list` and `agent get` alike. Appending keeps positional subcommand
arguments at fixed argv indices, which is what the test stubs in `tests/fixtures/` parse. `terminal.lua`
uses the leading form for the TUI (`herdr --session <name>`), which is the usage line herdr documents for
launching a client. `HERDR_SESSION` is not used: an explicit flag is visible in `ps` output and does not
leak into whatever the herdr TUI spawns.

## Exit codes and errors

- Server NOT running: `herdr agent list` prints `Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }` to stderr, exit code 1.
- Server running: exit 0 with JSON on stdout.
- `herdr status` works with or without server (plain YAML-ish text, NOT JSON):

```
client:
  version: 0.7.5
  channel: stable
  protocol: 17

server:
  status: running        <- or "not running"
  version: 0.7.5
  protocol: 17
  compatible: yes
  socket: ~/.config/herdr/herdr.sock
```

## Error envelope for API-level failures (verified 2026-07-24, herdr 0.7.5)

When the server IS running but the request itself fails, herdr does not print a plain message. It prints a
JSON error envelope on **stderr** (stdout stays empty) and exits 1:

```
$ herdr agent get no-such-target-zzz
{"error":{"code":"agent_not_found","message":"agent target no-such-target-zzz not found"},"id":"cli:agent:get"}
$ echo $?
1
```

Envelope: `{ error: { code: string, message: string }, id: string }` - the mirror image of the success
envelope's `result`.

`cli.normalize_error` extracts `.error.message` and shows `herdr: <message>`; the raw envelope must never
reach the user. The two failure shapes are therefore distinct:

| condition | stderr | exit |
|---|---|---|
| server not running | `Error: Os { code: 2, kind: NotFound, ... }` (plain Rust debug) | 1 |
| server running, request invalid | JSON error envelope above | 1 |

## agent list (JSON by default - there is NO --json flag; passing one prints usage and fails)

```
$ herdr agent list
{"id":"cli:agent:list","result":{"agents":[],"type":"agent_list"}}
```

Envelope: `{ id: string, result: { agents: AgentInfo[], type: "agent_list" } }`

## AgentInfo shape (from `herdr api schema --json`, success_response $defs)

Required: `terminal_id`, `agent_status`, `workspace_id`, `tab_id`, `pane_id`, `focused` (bool), `revision` (int).
Nullable strings: `agent` (kind e.g. "claude"), `display_agent`, `name`, `title`, `terminal_title`, `cwd`.

`agent_status` enum: `"idle" | "working" | "blocked" | "done" | "unknown"` (AgentStatus in schema).

Normalization for the plugin: display name = `name` or `display_agent` or `agent` or `title` or `pane_id`; state = `agent_status`.

## The id hierarchy (verified 2026-07-30, herdr 0.7.5)

herdr nests workspace -> tab -> pane, and an agent is a process herdr detects INSIDE a pane. The ids are
hierarchical strings that repeat their parent: a workspace is `w5`, its first tab is `w5:t1`, its panes are
`w5:p1`, `w5:p2`. An `AgentInfo` carries `workspace_id`, `tab_id` and `pane_id` but **no workspace label**,
so a UI that wants to say which workspace an agent is in has to resolve the label separately - hence
`workspace list`.

## workspace list (verified 2026-07-30, herdr 0.7.5)

```
$ herdr workspace list
{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"active_tab_id":"wA:t1","agent_status":"unknown","focused":true,"label":"rware","number":1,"pane_count":1,"tab_count":1,"workspace_id":"wA"}]}}
```

Envelope: `{ id: string, result: { type: "workspace_list", workspaces: WorkspaceInfo[] } }`

`WorkspaceInfo` (from `herdr api schema --json`, `$defs.WorkspaceInfo`) - all required:
`workspace_id`, `number` (uint), `label`, `focused` (bool), `pane_count` (uint), `tab_count` (uint),
`active_tab_id`, `agent_status`. Optional: `tokens` (string map), `worktree` (nullable object).

Two facts the grouped agents float depends on:

- `agent_status` here is a **rollup** for the whole workspace, using the same
  `idle | working | blocked | done | unknown` enum as an agent's.
- **Labels are NOT unique.** Several workspaces were observed all labelled `"rware"`, so a UI must always
  disambiguate with the `workspace_id` (or `number`); the label alone is not an identity.

`herdr tab list` is the same shape one level down - `{ id, result: { tabs: TabInfo[], type: "tab_list" } }`
with `tab_id`, `workspace_id`, `label`, `number`, `focused`, `pane_count`, `agent_status`:

```
$ herdr tab list
{"id":"cli:tab:list","result":{"tabs":[{"agent_status":"unknown","focused":true,"label":"1","number":1,"pane_count":1,"tab_id":"wA:t1","workspace_id":"wA"}],"type":"tab_list"}}
```

The plugin does not call `tab list`: the agent list already carries `tab_id`, and the grouped float renders
the tab as part of a row's shortened location rather than as a third nesting level.

## Other verified subcommands

- `herdr agent get/read/send-keys/prompt/rename/focus/wait/attach/start/explain` exist (same socket-API JSON envelope style).
- `herdr api snapshot` prints full session snapshot JSON: `{"id":"cli:api:snapshot","result":{"snapshot":{"agents":[],"layouts":[],"panes":[],"protocol":17,"tabs":[],"version":"0.7.5","workspaces":[]},"type":"session_snapshot"}}`
- `herdr server stop` stops the server. Running `herdr server` (foreground) starts a headless server.

## Fixture guidance

Stub scripts should emit the real envelope, e.g.:

```json
{"id":"cli:agent:list","result":{"agents":[
  {"terminal_id":"t1","agent_status":"working","workspace_id":"w1","tab_id":"tb1","pane_id":"p1","focused":true,"revision":3,"agent":"claude","name":"claude-1","title":null},
  {"terminal_id":"t2","agent_status":"blocked","workspace_id":"w1","tab_id":"tb1","pane_id":"p2","focused":false,"revision":5,"agent":"codex","name":null,"display_agent":"codex"},
  {"terminal_id":"t3","agent_status":"done","workspace_id":"w1","tab_id":"tb2","pane_id":"p3","focused":false,"revision":2,"agent":"claude","name":"reviewer"}
],"type":"agent_list"}}
```

Failure fixture: print the `Error: Os {...}` line to stderr and exit 1 (mimics server-down).

A stub that also answers `workspace list` (see `tests/fixtures/herdr-stub-multi`) must emit the workspace
envelope verbatim, including the hierarchical ids, or the plugin's prefix stripping has nothing to strip:

```json
{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[
  {"active_tab_id":"w5:t1","agent_status":"blocked","focused":false,"label":"rware","number":3,"pane_count":2,"tab_count":1,"workspace_id":"w5"},
  {"active_tab_id":"w7:t1","agent_status":"working","focused":true,"label":"api-refactor","number":1,"pane_count":1,"tab_count":1,"workspace_id":"w7"}
]}}
```
