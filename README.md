# herdr.nvim

A floating modal terminal for [herdr](https://herdr.dev), the agent multiplexer, plus agent-state visibility inside Neovim: a status float, a statusline component, and highlight groups that follow your colorscheme.

## Features

- **Floating terminal** - One key opens the full herdr TUI in a centered float. Toggle-off hides it, so scrollback survives and reopening is instant.
- **Agent status float** - `:HerdrAgents` lists every agent herdr knows about with its state, grouped by workspace, refreshable in place, with a per-agent detail view.
- **Background polling** - `herdr agent list` on a timer, with an in-flight guard so a slow call never stacks subprocesses. Self-disables after repeated failures instead of nagging you forever.
- **Lualine component** - Working / blocked / done / idle counts in your statusline, colored by the worst state present, hidden when there is nothing to say and marked `!` when polling has given up.
- **Colorscheme adaptive** - Five highlight groups, all `default` links to builtin diagnostic groups, re-applied after a colorscheme switch.
- **Health check** - `:checkhealth herdr` verifies the Neovim version, the binary, the server, and your config.
- **No dependencies** - Pure Lua against the herdr CLI. Lualine is optional.

## Requirements

- **Neovim >= 0.11.** The terminal is started with `jobstart({ term = true })` and several modules use the 4-argument `vim.validate()`. Both landed in 0.11. On 0.10 the `term` flag is silently ignored, so `:Herdr` would open an empty float, and `vim.validate()` raises outright.
- **The `herdr` binary on `$PATH`:**

  ```sh
  curl -fsSL https://herdr.dev/install.sh | sh
  ```

  If it lives somewhere off `$PATH`, point at it with `cmd = "/path/to/herdr"`.
- **No plugin dependencies.** [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) is optional and only needed for the statusline component.

## Installation

### lazy.nvim

```lua
{
  dir = "~/herdr.nvim",
  -- or "raymondware/herdr.nvim",
  -- VeryLazy, not cmd/keys: lazy.nvim only puts a plugin's directory on
  -- runtimepath when it loads, so a cmd-lazy herdr makes ":checkhealth herdr"
  -- report "no healthcheck found" and leaves the lualine component empty
  -- until the first toggle.
  event = "VeryLazy",
  keys = {
    { "<C-g>", function() require("herdr").toggle() end, desc = "herdr: toggle terminal" },
    { "<leader>ha", function() require("herdr").agents() end, desc = "herdr: agent status" },
  },
  config = function()
    require("herdr").setup({
      -- lazy's `keys` above owns the mappings, so setup() must not also claim
      -- one; two owners on the same lhs is a race nobody wins.
      keymaps = { toggle = false },
      -- Loading early must not mean polling early: no subprocess runs until
      -- :HerdrAgents or :HerdrPoll start asks for one.
      agents = { auto_start = false },
    })
  end,
}
```

`keymaps = { toggle = false }` matters when you use lazy's `keys`. Left at its default, `setup()` maps `<C-r>` itself, and you would have two mappings fighting over the toggle - lazy's on your chosen key and the plugin's on `<C-r>`. Pick one owner. If you would rather let `setup()` do it, drop the `keys` block and set `keymaps.toggle` to the key you want.

Why `event = "VeryLazy"` rather than lazy-loading by `cmd`: lazy.nvim only adds a plugin's
directory to `runtimepath` at the moment it loads. Under `cmd` lazy-loading, `:checkhealth herdr`
answers "no healthcheck found" and the lualine component renders nothing until you first press
the toggle, which rather defeats an at-a-glance agent indicator. Loading just after startup fixes
both, and `agents.auto_start = false` keeps the cost at zero until you actually ask for agent
state: no `herdr agent list` subprocess runs until `:HerdrAgents` or `:HerdrPoll start`.

If you would rather have counts without asking, drop `auto_start` (it defaults to `true`) and
polling begins with `setup()`, costing one short-lived subprocess per `poll_interval_ms`.

## The `<C-r>` caveat

**The default toggle key is `<C-r>`, which shadows normal-mode redo.** This is deliberate (herdr's own prefix is `ctrl+b`, and `<C-r>` is close to the `ctrl` muscle memory the TUI expects) but it is a real tradeoff, so `:checkhealth herdr` reports it as an info line while it is in effect. Redo is still reachable as `:redo`, `:red`, or `g-`/`g+`, but if you use `u`/`<C-r>` all day, change it:

```lua
require("herdr").setup({
  keymaps = { toggle = "<C-g>" }, -- any lhs you like
})
```

Or take the plugin out of the keymap business entirely:

```lua
require("herdr").setup({
  keymaps = { toggle = false }, -- no normal-mode mapping at all
})
```

A later `setup()` call that unsets or retargets a mapping also removes the old one, so flipping `toggle` to `false` after a default `setup()` really does give you redo back. Only mappings this plugin created are ever removed; a mapping that no longer carries the plugin's own `desc` is treated as yours and left alone.

The same key is also mapped **buffer-locally in terminal mode** inside the herdr float, so the key that opened the float also dismisses it without going through `<C-\><C-n>` first. If your herdr TUI or the agent running in it needs `ctrl+r` (reverse history search, for instance), turn the terminal-mode half off and keep the normal-mode half:

```lua
require("herdr").setup({
  keymaps = { toggle_in_terminal = false },
})
```

There is no default mapping for the agents float; set `keymaps.agents` if you want one.

## Configuration

`setup()` is required - the commands, keymaps and highlight groups are all registered there. These are the complete defaults:

```lua
require("herdr").setup({
  cmd = "herdr", -- binary name, or an absolute path
  session = nil, -- named herdr session; every call gets `--session <name>`
  extra_args = {}, -- extra argv appended to the TUI command

  window = {
    width = 0.85, -- fraction of `columns` (values > 1 are absolute cells)
    height = 0.85, -- fraction of `lines` (values > 1 are absolute cells)
    border = "rounded", -- any `nvim_open_win` border, or "none"
    title = " herdr ", -- border title; ignored when border = "none"
  },

  agents_window = {
    width = 72, -- absolute cells here (values <= 1 are fractions)
    height = 0.5,
    border = "rounded",
    title = " herdr agents ",
  },

  terminal = {
    auto_insert = true, -- enter insert mode on open and on re-entry
    persist_buffer = true, -- toggle-off hides; false kills the client job
    close_on_exit = true, -- close the float when the herdr client exits
  },

  keymaps = {
    toggle = "<C-r>", -- normal-mode toggle; false disables (see the caveat above)
    toggle_in_terminal = true, -- also map `toggle` in terminal mode, buffer-local
    agents = nil, -- optional normal-mode key for :HerdrAgents
  },

  agents = {
    enabled = true, -- false disables polling and the agent UI's auto-start
    auto_start = true, -- start polling from setup() rather than on first UI open
    poll_interval_ms = 5000, -- time between `herdr agent list` calls (floor 100)
    cli_timeout_ms = 4000, -- per-call timeout for herdr subprocesses
    max_failures = 3, -- consecutive failures before polling self-stops (min 1)
  },

  lualine = {
    icons = {
      working = "●",
      blocked = "▲",
      done = "✓",
      idle = "○",
    },
    format = "{working} {blocked} {done} {idle}", -- see the lualine section
    hide_when_zero = true, -- drop a token entirely when its count is 0
    show_when_idle = false, -- show the segment when there are no agents at all
  },
})
```

Calling `setup()` again re-merges from the defaults rather than from the previous options, so it is idempotent and a value you stop passing really does go back to its default.

### The options worth explaining

**`terminal.persist_buffer`** - Toggling the float off only closes the window. The buffer and the herdr client job stay alive, so your scrollback is intact and the next toggle is instant rather than a fresh TUI startup. The herdr *server* persists either way, so this is not about losing agents; it is about not paying to reattach every time you glance away. Set it to `false` if you would rather the client job die on every toggle-off. `:HerdrKill` is the explicit teardown that always kills, whatever this is set to.

**`terminal.close_on_exit`** - When the herdr client exits, the float closes and the buffer is wiped. This covers both quitting herdr from inside the TUI and detaching with `ctrl+b q`: from Neovim's side those look the same, the client process ended. Set it to `false` to leave the float open on a dead job, showing whatever the TUI last painted. Note that a stale buffer cannot host a new job, so the next `:HerdrOpen` starts fresh regardless.

**`session`** - Points the whole plugin at a named herdr session instead of the default one. A named session is a separate server with its own socket, so this is threaded through *both* halves: the TUI is launched as `herdr --session <name>`, and every `herdr agent list` / `agent get` the poller runs carries the same flag. Left unset, everything talks to the default session.

**`agents.poll_interval_ms` and `agents.max_failures`** - Every poll is one `herdr agent list` subprocess, so the interval is a real cost, and `:checkhealth herdr` warns below 1000ms. Values below 100ms are clamped to 100ms, and a value that is not a number at all falls back to the 5000ms default: a zero or negative interval would otherwise re-spawn herdr as fast as it can exit. An unusable `cli_timeout_ms` (non-numeric, zero or negative) falls back to its default the same way, since a timeout that kills every child before it can answer is not a choice anyone made. After `max_failures` consecutive failures (server down, binary gone, timeouts) polling stops itself, warns once with the last error, and marks the state degraded. That is a deliberate design: an editor should not spawn a doomed subprocess every five seconds forever. `max_failures` below 1 is read as 1 rather than as "never give up", since giving up is the whole point of the budget. Cached counts stay on screen rather than blanking out, the agents float shows the reason on a `polling stopped: ...` line, and the lualine segment stays visible with a `!` marker. Re-arm it with `:HerdrPoll start` once herdr is back; a successful poll clears the degraded flag.

**`agents.enabled = false`** - Turns polling off entirely. `:HerdrPoll start` then warns instead of starting, and opening the agents float does not arm the timer, so the float shows only whatever was already cached.

**`agents_window`** - Sizes the `:HerdrAgents` float. Same rule as `window`: values `<= 1` are fractions of the editor, larger values are absolute cells, so the default is 72 columns wide and half the editor tall.

**`lualine.show_when_idle`** - Whether the statusline segment appears when herdr knows about no agents at all. Only reachable with `hide_when_zero = false`, because otherwise the all-zero text is already empty and the segment hides itself anyway.

## Commands

| Command | Description |
| --- | --- |
| `:Herdr` | Toggle the floating herdr terminal |
| `:HerdrOpen` | Open (or focus) the floating herdr terminal |
| `:HerdrClose` | Hide the floating terminal (buffer + job persist by default) |
| `:HerdrKill` | Kill the herdr client job and wipe the terminal buffer |
| `:HerdrAgents` | Toggle the agent status float |
| `:HerdrStatus` | Print a terminal/polling status summary |
| `:HerdrPoll [start\|stop\|toggle]` | Control agent polling; the argument defaults to `toggle` and tab-completes |

Each has a Lua equivalent: `require("herdr").toggle()`, `.open()`, `.close()`, `.kill()`, `.agents()`, `.poll(action)`, and `.status()`, which returns the snapshot table `:HerdrStatus` summarizes:

```lua
{
  available = true, -- the herdr binary is executable
  cmd = "herdr",
  terminal = { open = false, running = false },
  agents = { polling = true, counts = {...}, degraded = false, last_error = nil },
}
```

Before `setup()` runs, the only command registered is `:HerdrSetup`, which exists purely to tell you to call `setup()`. It is deleted once you do.

## The agents float

`:HerdrAgents` opens a read-only float over the editor. It never polls: it renders the poller's cache and subscribes to poll updates, so it repaints as new data lands.

The header tallies the agents (`3 agents  1 working  1 blocked  1 done`, with idle and unknown appended only when non-zero). Under it the agents are grouped by the workspace they live in:

```
3 agents  1 working  1 blocked  1 done

 rware (w5)          ▲ blocked
   ▲ claude-1      blocked  t1:p2       /tmp/api
   ● reviewer      working  t1:p3       claude

 api-refactor (w7)   ● working
   ● codex         working  t1:p1       /tmp/refactor
```

A group header is the workspace's label with its id, followed by that workspace's rolled-up state. The id is always there because herdr labels are **not unique** - several workspaces really can be called `rware`, and only the id tells them apart. The label comes from `herdr workspace list`, and so does the rollup; a workspace that call does not mention falls back to its bare id and rolls up from its own rows instead, worst state first.

Each agent row is the state icon, the display name, the state colored by state, where the agent sits inside its workspace, and a trailing hint - the agent's working directory if herdr reports one, otherwise its terminal title or kind. The location drops the redundant workspace prefix herdr puts on every id, so a tab of `w5:t1` and a pane of `w5:p2` render as `t1:p2` under the `w5` header rather than repeating the workspace three times. A long working directory runs off the right edge instead of pushing the columns out of alignment; widen `agents_window.width` if you want to see all of it.

Ordering is fixed so the view does not move under your cursor between polls: workspaces in herdr's own order (by workspace number), then any workspace the label lookup did not know, then a final `(unknown workspace)` group for agents herdr reports without a workspace at all. Inside a group the worst state comes first (blocked, working, done, idle, unknown), then name.

With no agents you get a single `No agents` line and no group headers. If polling has degraded, the reason is shown above the groups.

Resolving the labels costs one extra `herdr workspace list` call: one when the float opens, and one per poll while it stays open, since a workspace's rolled-up state is exactly as volatile as the rows underneath it. Nothing is spawned per redraw, and nothing runs once the float is closed. If that call fails there is no warning and nothing is lost except the labels - the headers show raw workspace ids and every agent row stays exactly where it was.

| Key | Action |
| --- | --- |
| `q` | Close the float |
| `<Esc>` | Close the float |
| `r` | Refresh now (a one-shot poll, independent of the timer) |
| `<CR>` | Open the detail float for the agent on the cursor line |

Closing the float does **not** stop polling, because the lualine component may still be consuming it.

`<CR>` on an agent line runs a single `herdr agent get` and opens a smaller float above the list with that agent's fields, aligned one per line: name, state, kind, focused, pane, tab, workspace, terminal, title, cwd. Those are the full, unshortened ids, so the detail float is where you go for the value you would paste into a `herdr` command. Fields herdr does not report are omitted rather than shown as blanks. It is a snapshot - it never repaints under you - and `q` or `<Esc>` closes it and hands focus back to the list. `<CR>` on the header, a workspace header, a blank separator, the degraded notice, or the `No agents` line does nothing.

Repaints carry the cursor with the agent it is on, so a `polling stopped: ...` notice appearing above the list (or clearing again), or a poll that regroups the workspaces, cannot leave `<CR>` pointed at a row you did not pick.

## Lualine

The component reads only the poller's cache, so it costs nothing per redraw and cannot throw into your statusline.

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      require("herdr.lualine").component(),
      "encoding",
      "filetype",
    },
  },
})
```

If herdr.nvim is lazy-loaded by `cmd`/`keys`, use the pcall wrapper instead. The direct form calls `require("herdr.lualine")` while your lualine config is being built, which force-loads the plugin and defeats the lazy-loading you asked for. Worse, if the plugin is not on the runtimepath yet, the `require` throws and takes your statusline config with it:

```lua
local function herdr_component()
  local ok, herdr = pcall(require, "herdr.lualine")
  if not ok then
    return ""
  end
  return herdr.component_text()
end

require("lualine").setup({
  sections = { lualine_x = { herdr_component, "encoding", "filetype" } },
})
```

The wrapper trades away the component's `cond` and `color`, so you get the text without the severity coloring and without the auto-hide. It returns an empty string when there is nothing to show, which lualine renders as an empty segment.

`lualine.format` is a template. Each `{token}` expands to that state's icon followed by its count:

| Token | Expands to |
| --- | --- |
| `{working}` | `● 2` |
| `{blocked}` | `▲ 1` |
| `{done}` | `✓ 3` |
| `{idle}` | `○ 4` |
| `{unknown}` | the bare count (no icon is defined for it) |
| `{total}` | the bare count of all agents |

Anything else in the template is passed through verbatim; an unrecognized `{token}` expands to nothing rather than leaking braces. With `hide_when_zero = true` a zero count drops its whole token, and the leftover whitespace is collapsed, so you never see `● 0` or a double space.

`{idle}` is in the default format for a reason: a session whose agents are all idle is a perfectly ordinary state, and without an idle token `hide_when_zero` would collapse the whole template to an empty string and hide the segment while `:HerdrAgents` was still listing agents. Drop `{idle}` from your own format if you only care about the busy states, and accept that an idle-only fleet then shows nothing.

The component's color follows the worst state present: blocked borrows `DiagnosticError`, working borrows `DiagnosticWarn`, and otherwise it borrows `DiagnosticOk`.

**Degraded polling stays visible.** When the poller gives up, the segment does not disappear - that would hide the problem at the exact moment you need to see it. Instead the last known counts are kept, prefixed with `!`, and colored with the error color: `! ● 2 ▲ 1`. With nothing cached to show, the segment reads `! herdr stopped`. Either way `:HerdrPoll start` re-arms it, and the marker goes away as soon as a poll succeeds.

Otherwise the component hides itself when polling is off (nothing is refreshing the counts, so showing them would be a lie), when the rendered text is empty, or when there are no agents at all and `lualine.show_when_idle` is false.

## Highlight groups

All five are created as `default` links, so your colorscheme or an explicit `:highlight` always wins. They are re-applied after a `ColorScheme` event, since some colorschemes clear non-builtin groups when they load.

| Group | Links to | Used for |
| --- | --- | --- |
| `HerdrAgentWorking` | `DiagnosticWarn` | The `working` state, on a row or a workspace rollup |
| `HerdrAgentBlocked` | `DiagnosticError` | The `blocked` state, and error lines in both floats |
| `HerdrAgentDone` | `DiagnosticOk` | The `done` state |
| `HerdrAgentIdle` | `Comment` | The `idle` and `unknown` states, the `No agents` line, and detail labels |
| `HerdrHeader` | `Title` | The agents float header line and each workspace group title |

## Health

```vim
:checkhealth herdr
```

It reports:

- Neovim >= 0.11, as an error if not.
- Whether the configured `cmd` is executable, with the install URL and the `cmd = "/path/to/herdr"` escape hatch in the advice.
- The binary's `--version` output.
- Whether the herdr server is running. A stopped server is a warning, not an error, because `:Herdr` starts it on attach.
- An info line while `keymaps.toggle` is still `<C-r>`, so the redo shadowing is never a surprise.
- A warning if `agents.poll_interval_ms` is under 1000ms.

Every probe is synchronous with a short timeout, and each section is independently contained, so one wedged probe cannot abort the report.

## Terminal-mode tips

- **`<C-\><C-n>` leaves terminal mode.** That is how you get to normal mode inside the float to scroll back, search, or yank out of the TUI's output.
- **`<Esc>` is passed straight through to herdr.** No `<Esc>` mapping is installed, on purpose: the herdr TUI needs raw Escape, and stealing it would break the thing you opened the float for.
- **`ctrl+b q` detaches herdr.** The client process ends, so with `close_on_exit = true` the float closes with it. The herdr server keeps running and every agent keeps working; the next `:Herdr` reattaches.
- **The float re-enters insert mode when you come back to it**, so the TUI is immediately interactive. Set `terminal.auto_insert = false` if you would rather land in normal mode.
- **The float follows editor resizes**, staying centered at its configured fraction.

## Status

Personal project / WIP.
