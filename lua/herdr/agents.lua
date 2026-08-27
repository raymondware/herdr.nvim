-- Agent polling engine: the SOLE owner of a uv timer in this plugin.
--
-- WHY the timer discipline below is strict: a uv handle that is stopped but
-- never closed keeps the event loop alive, which makes headless nvim hang on
-- exit. So there is exactly one handle, stop() stops AND closes it before
-- dropping the reference, and init.lua's VimLeavePre hook calls cleanup().
--
-- Nothing here arms a timer at require() time; start() is always explicit
-- (init.setup() when agents.enabled and agents.auto_start, or the UI).

local cli = require("herdr.cli")
local config = require("herdr.config")

local M = {}

-- The one timer handle; nil whenever polling is off.
local timer = nil

-- Bumped on every start(). Ticks carry the generation they were armed under so
-- a tick left queued by a stopped timer cannot poll under a newer one.
local timer_generation = 0

-- Set from the moment a request is spawned until its callback lands. A tick
-- that arrives while it is set returns immediately, so a slow herdr call can
-- never stack subprocesses behind itself.
local in_flight = false

-- Last known agent list. Deliberately kept on failure so the UI can render
-- stale data plus the degraded flag instead of blanking out.
local cache = {}

local consecutive_failures = 0
local degraded = false
local last_err = nil

-- Listener registry keyed by an opaque id so unsubscribe is O(1) and safe to
-- call more than once.
local listeners = {}
local next_listener_id = 0

-- refresh() callbacks coalesced onto the request that is already in flight.
local pending = {}

-- config.options is {} until setup() runs; fall back to defaults so every
-- entry point is safe pre-setup (same convention as cli.lua).
local function agents_opt(key)
  local opts = config.options.agents or config.defaults.agents
  local value = opts[key]
  if value == nil then
    return config.defaults.agents[key]
  end
  return value
end

local function cmd_name()
  return config.options.cmd or config.defaults.cmd
end

--- Identity of the subprocess a request is spawned with. A response whose key
--- no longer matches the current config was produced by a command the user has
--- since reconfigured away from, so it must not be cached or published (see
--- poll()). cmd + session is the whole identity: they are the only config
--- values that decide WHICH herdr server answers.
---
--- Delegated to cli.lua so the poll and agents_ui.lua's workspace lookup compare
--- against the same definition; looked up on the module table at call time, like
--- every other cli entry point this module uses.
---@return string
local function spawn_key()
  return cli.spawn_key()
end

-- WHY a floor and not a raw pass-through: uv treats a repeat of 0 as one-shot,
-- which would silently stop polling after the first tick, and a sub-100ms
-- interval turns the editor into a subprocess fountain. The in-flight guard
-- already serializes requests, so a 0/negative interval cannot pile processes
-- up, but it would still spin the loop and re-spawn as fast as herdr can exit.
-- 100ms is far below any sane configured value (:checkhealth warns under
-- 1000ms) and far above "as fast as possible".
local MIN_POLL_INTERVAL_MS = 100

--- Coerce a numeric option, clamped to `min`.
---
--- WHY this is not optional: config.setup() validates nothing, so a stringly
--- typed `max_failures = "3"` used to reach a `>=` comparison INSIDE the
--- vim.system callback, where a throw does not propagate to a caller - it is
--- reported by the scheduler and the callback is simply lost. Every numeric
--- option is therefore coerced at read time and never trusted.
---@param key string
---@param min integer
---@return integer
local function agents_num(key, min)
  local value = tonumber(agents_opt(key))
  -- NaN and +/-inf survive tonumber but not timer:start(), so anything
  -- non-finite falls back to the default too.
  if value == nil or value ~= value or value == math.huge or value == -math.huge then
    value = config.defaults.agents[key]
  end
  return math.max(min, math.floor(value))
end

---@return integer
local function poll_interval_ms()
  return agents_num("poll_interval_ms", MIN_POLL_INTERVAL_MS)
end

--- Anything below 1 is treated as 1 rather than as "never degrade": the whole
--- point of the failure budget is to stop an editor from spawning a doomed
--- subprocess forever, so when the value is nonsense the safer reading is to
--- give up sooner, not never.
---@return integer
local function max_failures()
  return agents_num("max_failures", 1)
end

local function warn(msg)
  vim.notify("herdr: " .. msg, vim.log.levels.WARN, { title = "herdr" })
end

--- Fan out to on_update listeners. Each call is pcall-contained: a broken
--- consumer must not kill polling, and notifying about it here would spam
--- once per tick, so listener errors are dropped on purpose.
---@param err string|nil
local function emit(err)
  -- Snapshot first: a listener is allowed to unsubscribe itself (or another)
  -- from inside the callback.
  local snapshot = {}
  for _, fn in pairs(listeners) do
    snapshot[#snapshot + 1] = fn
  end
  local list = M.get()
  for _, fn in ipairs(snapshot) do
    pcall(fn, list, err)
  end
end

---@param list table[]|nil
---@param err string|nil
local function flush_pending(list, err)
  if #pending == 0 then
    return
  end
  local waiting = pending
  pending = {}
  for _, cb in ipairs(waiting) do
    pcall(cb, list, err)
  end
end

--- Bookkeeping half of a resolved poll: cache, error latch, failure budget.
--- Split out of finish() so it can run under pcall - see finish().
---@param list table[]|nil
---@param err string|nil
local function record(list, err)
  if list then
    cache = list
    last_err = nil
    consecutive_failures = 0
    degraded = false
    return
  end

  last_err = err or "unknown herdr error"
  consecutive_failures = consecutive_failures + 1
  -- Degradation is a property of the poll loop: a one-shot refresh failure
  -- surfaces through last_error() and listeners instead of tearing anything
  -- down, so this only fires while a timer is armed.
  if timer and consecutive_failures >= max_failures() then
    M.stop()
    degraded = true
    warn(
      ("agent polling stopped after %d consecutive failures: %s (:HerdrPoll start to retry)"):format(
        consecutive_failures,
        last_err
      )
    )
  end
end

--- Resolve one poll: update state, then wake refresh() callbacks and on_update
--- listeners (in that order, so a listener already sees is_degraded()).
---
--- INVARIANT: for ANY config values whatsoever, a poll ends with in_flight
--- cleared, every pending callback invoked exactly once, and listeners fired
--- exactly once. That is why record() runs under pcall and the fan-out below is
--- UNCONDITIONAL. cli.lua promises cb exactly once (see its INVARIANT comment);
--- this is where that promise used to die from the inside: a throw in the
--- bookkeeping - a stringly-typed max_failures, or a vim.notify replacement that
--- errors - landed AFTER in_flight was cleared but BEFORE the callbacks ran, so
--- every refresh() callback and every listener was lost forever, the float and
--- the statusline froze, and nothing was surfaced to the user.
---
--- An error from record() is dropped rather than notified, for the same reason
--- emit() drops listener errors: it would spam once per tick.
---@param list table[]|nil
---@param err string|nil
local function finish(list, err)
  in_flight = false
  pcall(record, list, err)
  flush_pending(list, err)
  emit(err)
end

--- Spawn one `herdr agent list` unless a request is already out.
---
--- The spawn key is captured here and re-checked on delivery: a response
--- produced by a cmd/session the user has since reconfigured away from is NOT
--- data about the current config, so caching it (or handing it to a coalesced
--- refresh callback) would present the previous configuration's agents as
--- current, with last_error() == nil and no degraded flag - indistinguishable
--- from correct data. Same discipline as the detail float's token in
--- agents_ui.lua. Pending callbacks are never abandoned: a discarded response
--- re-issues the request under the new config instead of dropping them.
local function poll()
  if in_flight then
    return
  end
  in_flight = true
  local key = spawn_key()
  cli.agent_list(function(list, err)
    if key ~= spawn_key() then
      in_flight = false
      -- Re-issue for anyone still waiting, and for an armed timer so the
      -- swapped-in config produces data now rather than an interval later.
      if #pending > 0 or timer then
        poll()
      end
      return
    end
    finish(list, err)
  end)
end

--- Timer callback. Both checks matter. A tick can already be queued on the main
--- loop when stop() runs, so it must not spawn anything then; and because ticks
--- are schedule_wrap'd, a tick queued by a PREVIOUS timer can still be waiting
--- when start() re-arms, which the timer check alone would let through as a
--- spurious extra poll on the new generation.
local function tick(generation)
  if not timer or generation ~= timer_generation then
    return
  end
  poll()
end

--- Arm the poll timer. Idempotent, and it re-validates preconditions: a
--- config change that disables polling or points cmd at a missing binary also
--- takes down a timer armed by an earlier setup().
function M.start()
  if not agents_opt("enabled") then
    M.stop()
    warn("agent polling is disabled (agents.enabled = false)")
    return
  end
  if not cli.available() then
    M.stop()
    warn(
      ("agent polling needs the herdr binary (%s not found); see :checkhealth herdr"):format(
        cmd_name()
      )
    )
    return
  end
  if timer then
    return
  end

  consecutive_failures = 0
  degraded = false
  timer = vim.uv.new_timer()
  timer_generation = timer_generation + 1
  local generation = timer_generation
  -- 0 delay: poll immediately so the first UI frame has data. schedule_wrap
  -- because uv callbacks run outside the main loop and cli/vim.notify need it.
  timer:start(0, poll_interval_ms(), vim.schedule_wrap(function()
    tick(generation)
  end))
end

--- Stop and close the timer. Safe when never started.
function M.stop()
  if not timer then
    return
  end
  -- Drop the module reference first so anything that lands mid-teardown
  -- (queued tick, in-flight callback) sees polling as off.
  local handle = timer
  timer = nil
  handle:stop()
  if not handle:is_closing() then
    handle:close()
  end
end

---@return boolean
function M.is_polling()
  return timer ~= nil
end

--- True once max_failures consecutive polls failed; cleared by a successful
--- poll or by start().
---@return boolean
function M.is_degraded()
  return degraded
end

---@return string|nil
function M.last_error()
  return last_err
end

--- One-shot poll, whether or not the timer is running (it arms nothing).
--- Shares the in-flight guard: when a request is already out, cb is coalesced
--- onto that request instead of spawning a second subprocess, so cb is always
--- honored with real data - and never with data from a superseded cmd/session,
--- because a coalesced-onto request whose config changed underneath it is
--- discarded and re-issued rather than delivered (see poll()).
---@param cb fun(agents: table[]|nil, err: string|nil)|nil
function M.refresh(cb)
  vim.validate("cb", cb, "callable", true)
  if cb then
    pending[#pending + 1] = cb
  end
  poll()
end

--- Last known agent list (normalized by cli.normalize_agent).
--- Shallow copy: consumers must not be able to mutate the cache.
---@return table[]
function M.get()
  local list = {}
  for i, agent in ipairs(cache) do
    list[i] = agent
  end
  return list
end

--- Per-state tallies derived from get(). Always all six keys.
---@return table {working, blocked, done, idle, unknown, total}
function M.counts()
  local counts = { working = 0, blocked = 0, done = 0, idle = 0, unknown = 0, total = 0 }
  for _, agent in ipairs(cache) do
    local state = agent.state
    -- Defends against enum drift and against a literal "total" state.
    if state == "total" or counts[state] == nil then
      state = "unknown"
    end
    counts[state] = counts[state] + 1
    counts.total = counts.total + 1
  end
  return counts
end

--- Subscribe to poll completions. fn(agents, err) fires after every poll,
--- successful or not, so the UI can render the degraded state too.
---
--- Listeners run after the in-flight guard is released, so a listener that calls
--- M.refresh() immediately spawns the next subprocess and becomes a
--- self-sustaining max-rate poll loop (bounded by the subprocess round trip, but
--- still one process per emit). Refresh from a keymap, not from a listener.
---@param fn fun(agents: table[], err: string|nil)
---@return fun() unsubscribe safe to call more than once
function M.on_update(fn)
  vim.validate("fn", fn, "callable")
  next_listener_id = next_listener_id + 1
  local id = next_listener_id
  listeners[id] = fn
  return function()
    listeners[id] = nil
  end
end

--- Full teardown: stop the timer and drop every listener. Idempotent and safe
--- when polling never started (init.lua calls this on VimLeavePre).
function M.cleanup()
  M.stop()
  listeners = {}
end

return M
