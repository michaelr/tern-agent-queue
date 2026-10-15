--!strict
-- Queue bookkeeping for agents that are waiting on the user. Pure Luau: no
-- `tern` calls, so the ordering rules can be exercised with a plain `luau`.
--
-- Rules:
--   * An agent enters the queue when it stops working (idle or waiting_input)
--     and leaves it as soon as it works again.
--   * An agent that goes away (unlisted, or exited) keeps its entry, hidden,
--     for GONE_GRACE seconds: Tern's daemon detaching and reattaching drops
--     every agent of the host from the list for a few seconds, and dropping
--     the entries then lost Done marks and order. Back in time, it carries
--     on as before; else the entry goes.
--   * A turn the poll missed (the state or the last message changed without
--     a working state seen in between) counts as leaving and entering again.
--     A last message changing in the first TURN_GRACE seconds, or appearing
--     where there was none, is taken as the agent's report catching up
--     instead (it lags the state): the entry keeps its place but drops its
--     context, which was read too early, so it is fetched again.
--   * Order is FIFO by entry, except that an agent asking a question
--     (waiting_input) jumps ahead of the ones that merely finished.
--   * Skip moves an entry to the back and drops its question priority.
--   * Dismiss hides an entry until the agent works again.

export type Context = {
	task: string?, -- first user prompt seen in the session
	last_prompt: string?, -- most recent user prompt
	branch: string?,
}

export type Entry = {
	pane: number,
	seq: number, -- FIFO position; larger enters later
	since: number, -- os.time() seconds when it entered
	state: string, -- "idle" | "waiting_input"
	turn: string?, -- the agent's last message when last seen; nil when unknown
	skipped: boolean?,
	dismissed: boolean?,
	gone: number?, -- os.time() when the agent stopped being listed; hidden meanwhile
	ctx: Context?, -- nil until fetched
}

-- A rolling summary of what an agent is on, from the smol model. Kept per
-- pane (not per entry) so the next summary can see the previous one.
export type Summary = {
	now: string, -- the task the agent is on, as of its latest turn
	status: string?, -- what it just finished or reported
	at: number, -- os.time() when summarized
	fingerprint: string, -- what was summarized; unchanged input is not re-run
}

-- A session's illustrated scene: a JPEG under the plugin's data directory,
-- made from the session's first prompt.
export type Scene = {
	path: string,
	task: string, -- fingerprint of the first prompt it was made from
}

export type Store = {
	entries: { [string]: Entry },
	seq: number,
	tasks: { [string]: string }?, -- first prompt per pane, kept while the pane lives
	summaries: { [string]: Summary }?, -- kept while the pane lives
	scenes: { [string]: Scene }?, -- kept while the pane lives
}

-- `turn` is the agent's last message, when known.
export type AgentState = { pane: number, state: string, turn: string? }

local M = {}

local QUEUED: { [string]: boolean } = { idle = true, waiting_input = true }

-- Tern reports an agent's last message seconds after its state (7 s seen).
local TURN_GRACE = 15

-- How long an entry outlives its agent going away: a daemon reattach takes
-- seconds, a Tern restart about a minute.
local GONE_GRACE = 600

function M.new(): Store
	return { entries = {}, seq = 0 }
end

local function valid(value: any): boolean
	return type(value) == "table" and type(value.entries) == "table" and type(value.seq) == "number"
end

-- Accepts whatever came back from tern.kv; anything malformed starts fresh.
function M.coerce(value: any): Store
	if not valid(value) then
		return M.new()
	end
	return value :: Store
end

-- Of `candidates` (saved stores by key, as read back, possibly malformed),
-- the key of the one this window's queue most likely was before its key
-- changed: the most entries whose pane is in `panes`, then the longest
-- history. Nil when none shares a pane.
function M.adopt(candidates: { [string]: any }, panes: { [string]: boolean }): string?
	local best: string? = nil
	local best_shared, best_seq = 0, -1
	for key, value in candidates do
		if valid(value) then
			local shared = 0
			for pane in value.entries do
				if panes[pane] then
					shared += 1
				end
			end
			if shared > best_shared or (shared == best_shared and shared > 0 and value.seq > best_seq) then
				best, best_shared, best_seq = key, shared, value.seq
			end
		end
	end
	return best
end

local function bump(store: Store): number
	store.seq += 1
	return store.seq
end

local function priority(e: Entry): number
	if e.state == "waiting_input" and not e.skipped then
		return 0
	end
	return 1
end

-- Applies the current agent states. Returns whether the store changed, the
-- panes that entered the queue (again, after a missed turn) and the panes that
-- left it.
function M.reconcile(store: Store, agents: { AgentState }, now: number): (boolean, { number }, { number })
	local changed = false
	local entered: { number } = {}
	local left: { number } = {}
	local seen: { [string]: boolean } = {}

	for _, a in agents do
		local key = tostring(a.pane)
		local e = store.entries[key]
		if a.state == "exited" then
			continue -- treated as not listed
		end
		seen[key] = true
		if e ~= nil and e.gone ~= nil then
			e.gone = nil
			changed = true
		end
		if QUEUED[a.state] then
			-- A missing turn on either side (an old store, an agent that hasn't
			-- said anything yet) is no evidence of a turn.
			local new_turn = e ~= nil and a.turn ~= nil and e.turn ~= a.turn
			local missed = e ~= nil
				and (e.state ~= a.state or (new_turn and e.turn ~= nil and now - e.since >= TURN_GRACE))
			if e == nil or missed then
				store.entries[key] = { pane = a.pane, seq = bump(store), since = now, state = a.state, turn = a.turn }
				table.insert(entered, a.pane)
				changed = true
			elseif new_turn then
				e.turn = a.turn
				e.ctx = nil
				changed = true
			end
		elseif e ~= nil then
			store.entries[key] = nil
			table.insert(left, a.pane)
			changed = true
		end
	end

	for key, e in store.entries do
		if not seen[key] then
			if e.gone == nil then
				e.gone = now
				changed = true
			elseif now - e.gone >= GONE_GRACE then
				store.entries[key] = nil
				table.insert(left, e.pane)
				changed = true
			end
		end
	end

	return changed, entered, left
end

-- Visible entries, head first.
function M.ordered(store: Store): { Entry }
	local out: { Entry } = {}
	for _, e in store.entries do
		if not e.dismissed and e.gone == nil then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a: Entry, b: Entry): boolean
		local pa, pb = priority(a), priority(b)
		if pa ~= pb then
			return pa < pb
		end
		if a.seq ~= b.seq then
			return a.seq < b.seq
		end
		return a.pane < b.pane
	end)
	return out
end

-- Entries marked done, in the order they entered the queue.
function M.dismissed(store: Store): { Entry }
	local out: { Entry } = {}
	for _, e in store.entries do
		if e.dismissed and e.gone == nil then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a: Entry, b: Entry): boolean
		if a.seq ~= b.seq then
			return a.seq < b.seq
		end
		return a.pane < b.pane
	end)
	return out
end

function M.get(store: Store, pane: number): Entry?
	local e = store.entries[tostring(pane)]
	if e and not e.dismissed and e.gone == nil then
		return e
	end
	return nil
end

function M.skip(store: Store, pane: number): boolean
	local e = M.get(store, pane)
	if e == nil then
		return false
	end
	e.seq = bump(store)
	e.skipped = true
	return true
end

function M.dismiss(store: Store, pane: number): boolean
	local e = M.get(store, pane)
	if e == nil then
		return false
	end
	e.dismissed = true
	return true
end

-- The pane to show after `focused`: when the focused pane is queued it is
-- skipped to the back first. Returns nil when nothing else is waiting.
function M.advance(store: Store, focused: number?): number?
	if focused ~= nil then
		M.skip(store, focused)
	end
	for _, e in M.ordered(store) do
		if e.pane ~= focused then
			return e.pane
		end
	end
	return nil
end

-- Counts for the status segment.
function M.counts(store: Store): (number, number)
	local total, asking = 0, 0
	for _, e in M.ordered(store) do
		total += 1
		if priority(e) == 0 then
			asking += 1
		end
	end
	return total, asking
end

return M
