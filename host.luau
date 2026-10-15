--!strict
-- Agent queue, host half: the plugin blocks, which unlike a canvas can show
-- images. "agent-queue.side" is the side pane; "agent-queue.picker" is the
-- picker, zoomed to fill the tab: every queued agent as a card in a grid,
-- picked with the arrows and Enter.
--
-- The queue lives in the window half. It publishes the view model to tern.kv
-- under "side:<pane>" or "picker:<pane>" (rev, model); a block polls its key
-- and redraws when the rev changes. Clicks and picks go back as
-- `agent-queue://<act>/<value>` links, which the window half claims
-- (tern.route.link) and acts on; it also closes the picker.

local view = require("./lib/view")
local picker = require("./lib/picker")

local POLL_MS = 250 -- how often a block looks for a new model
local SCENE_MAX_BYTES = 2 * 1024 * 1024

type State = {
	rev: number?,
	model: view.Model?,
	blobs: { [string]: string }, -- scene path -> blob id
	-- The picker's selection: the selected agent's pane, and its index, which
	-- a selected agent that leaves the queue hands on to its neighbour.
	selected: number?,
	index: number,
	top: number, -- the picker's first row in view
	query: string, -- the picker's search, typed into it
	browse: number?, -- the side pane's agent picked with ↑/↓ (nil: follow the current one)
}

local function alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

-- Blob ids for the scenes of `items`, read once per path.
local function images(state: State, cx: BlockCx, items: { view.Item }): { [string]: string }
	for _, item in items do
		local path = item.scene
		if path and state.blobs[path] == nil then
			local ok, bytes = pcall(tern.fs.read, path, SCENE_MAX_BYTES)
			if ok and type(bytes) == "string" then
				state.blobs[path] = cx:blob(bytes, "image/jpeg")
			end
		end
	end
	return state.blobs
end

local function poll(state: State, cx: BlockCx, prefix: string)
	local pane = cx.pane
	local key = prefix .. tostring(pane)
	local function tick()
		if not alive(pane) then
			return
		end
		local ok, data = pcall(tern.kv.get, key)
		if ok and type(data) == "table" and data.rev ~= state.rev and type(data.model) == "table" then
			state.rev = data.rev
			state.model = data.model
			cx:render()
		end
		tern.timer(POLL_MS, tick)
	end
	tick()
end

local function new_state(): State
	return { rev = nil, model = nil, blobs = {}, selected = nil, index = 1, top = 1, query = "", browse = nil }
end

local function waiting(): BlockView
	return { main = tern.ui.col({ tern.ui.text({ tern.ui.span("Waiting for the queue…", "muted") }) }) }
end

-- Clicks become links the window claims.
local function forward(_state: State, ev: UiEvent, cx: BlockCx)
	if ev.ev == "action" and type(ev.act) == "string" then
		cx:open("agent-queue://" .. ev.act .. "/" .. tostring(ev.value or ""))
	end
end

-- The side pane's list rows in order: Queue, then Running and Done unless
-- folded to their heading.
local function side_rows(model: view.Model): { view.Item }
	local out: { view.Item } = {}
	for _, item in model.items do
		table.insert(out, item)
	end
	for _, list in { { key = "running", items = model.running }, { key = "done", items = model.done } } do
		if model.folded[list.key] ~= true then
			for _, item in list.items do
				table.insert(out, item)
			end
		end
	end
	return out
end

-- The agent ↑/↓ moved to (`state.browse`), when it is still listed.
local function browsed(state: State, rows: { view.Item }): (view.Item?, number)
	for i, item in rows do
		if item.pane == state.browse then
			return item, i
		end
	end
	return nil, 0
end

-- The side block's width for the window half, which sizes it (tern.kv
-- "cols:<pane>"; the window clears it when the pane goes).
local function publish_width(cx: BlockCx, cols: number)
	pcall(tern.kv.set, "cols:" .. tostring(cx.pane), cols)
end

local side: BlockDef<State> = {
	init = function(cx, _args, _saved)
		local state = new_state()
		publish_width(cx, cx.cols)
		poll(state, cx, "side:")
		return state
	end,

	resize = function(_state, cols, _rows, cx)
		publish_width(cx, cols)
	end,

	title = function(state)
		local n = if state.model then #state.model.items else 0
		return if n > 0 then string.format("Agent queue · %d", n) else "Agent queue"
	end,

	view = function(state, cx)
		local model = state.model
		if model == nil then
			return waiting()
		end
		-- While browsing with ↑/↓, the card previews the highlighted agent
		-- (the model is read-only: a copy with another current).
		local item = browsed(state, side_rows(model))
		if item then
			local copy: any = {}
			for k, v in model :: any do
				copy[k] = v
			end
			copy.current = item
			model = copy
		else
			state.browse = nil
		end
		local m = model :: view.Model
		-- The card's scene, and each listed agent's as its row's icon.
		local shown = side_rows(m)
		if m.current then
			table.insert(shown, m.current)
		end
		return { main = view.build(m, images(state, cx, shown)), dock = view.dock(m) }
	end,

	-- ↑/↓ (or k/j) move through the list, previewing each agent in the card;
	-- Enter goes to it; Esc goes back to the current agent.
	key = function(state, key, cx)
		local model = state.model
		if model == nil or key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.name
		if k == "j" and not key.shift then
			k = "down"
		elseif k == "k" and not key.shift then
			k = "up"
		end
		local rows = side_rows(model)
		local item, i = browsed(state, rows)
		if k == "escape" or k == "esc" then
			if state.browse == nil then
				return false
			end
			state.browse = nil
			return true
		elseif k == "enter" then
			local target = item or model.current
			if target == nil then
				return false
			end
			state.browse = nil
			cx:open("agent-queue://go/" .. tostring(target.pane))
			return true
		elseif k ~= "up" and k ~= "down" then
			return false
		end
		if #rows == 0 then
			return false
		end
		if item == nil then
			-- Start from the card's agent.
			for j, row in rows do
				if model.current and row.pane == model.current.pane then
					i = j
				end
			end
		end
		local j = if i == 0 then 1 else math.clamp(i + (if k == "up" then -1 else 1), 1, #rows)
		if rows[j].pane == state.browse then
			return false
		end
		state.browse = rows[j].pane
		return true
	end,

	event = forward,
}

-- What the picker shows: Waiting, Running and Done, each cut to the agents
-- the search matches (on their title, place, folder, branch, task and
-- summary), and those agents in one list, the order of the grid.
type Shown = { groups: { view.PickerGroup }, items: { view.Item } }

local function shown(state: State): Shown
	local model = state.model
	local out: Shown = { groups = {}, items = {} }
	if model == nil then
		return out
	end
	local lists: { { label: string, items: { view.Item } } } = {
		{ label = "Waiting", items = model.items },
		{ label = "Running", items = model.running },
		{ label = "Done", items = model.done },
	}
	for _, list in lists do
		local label, items = list.label, list.items
		local group: view.PickerGroup = { label = label, items = {}, total = #items }
		for _, item in items do
			local fields: { string } = {}
			local function add(f: string?)
				if f then
					table.insert(fields, f)
				end
			end
			add(item.title)
			add(item.where)
			add(item.cwd)
			add(item.branch)
			add(item.task)
			add(item.now)
			if picker.matches(fields, state.query) then
				table.insert(group.items, item)
				table.insert(out.items, item)
			end
		end
		table.insert(out.groups, group)
	end
	return out
end

-- The grid's rows for `s` in a block `cols` wide.
local function grid(s: Shown, cols: number): { picker.Row }
	local counts: { number } = {}
	for _, g in s.groups do
		table.insert(counts, #g.items)
	end
	return picker.rows(counts, picker.per_row(cols))
end

-- The selected card's index among `items`, following the selected agent
-- through model changes (and from Waiting to Running and Done); the agent
-- the side pane shows is selected first.
local function selection(state: State, items: { view.Item }): number
	if #items == 0 then
		return 0
	end
	local current = if state.model then state.model.current else nil
	local want = state.selected or (if current then current.pane else nil)
	for i, item in items do
		if item.pane == want then
			state.selected, state.index = item.pane, i
			return i
		end
	end
	local i = math.clamp(state.index, 1, #items)
	state.selected, state.index = items[i].pane, i
	return i
end

-- Changes the search, selecting its first match.
local function search(state: State, query: string): boolean
	if query == state.query then
		return false
	end
	state.query = query
	local first = shown(state).items[1]
	state.selected, state.index, state.top = if first then first.pane else nil, 1, 1
	return true
end

local ARROWS: { [string]: picker.Dir } = { left = "left", right = "right", up = "up", down = "down" }

local pick: BlockDef<State> = {
	init = function(cx, _args, _saved)
		local state = new_state()
		poll(state, cx, "picker:")
		return state
	end,

	title = function(_state)
		return "Pick an agent"
	end,

	view = function(state, cx)
		if state.model == nil then
			return waiting()
		end
		local s = shown(state)
		local selected = selection(state, s.items)
		local per_row = picker.per_row(cx.cols)
		local rows = grid(s, cx.cols)
		local budget = cx.rows - picker.HEAD_ROWS
		local card_rows = picker.card_rows(cx.cols, per_row)
		-- Scrolled just enough to show the selection.
		local row = if selected > 0 then picker.row_of(rows, selected) else state.top
		state.top = picker.scroll(rows, state.top, row, budget, card_rows)
		return {
			main = view.picker({
				groups = s.groups,
				items = s.items,
				rows = rows,
				query = state.query,
				images = images(state, cx, s.items),
				selected = selected,
				per_row = per_row,
				top = state.top,
				last = if #rows > 0 then picker.last_shown(rows, state.top, budget, card_rows) else 0,
			}),
		}
	end,

	-- Typing searches; arrows, Enter and Esc act on the grid. Esc clears a
	-- search before it closes the picker.
	key = function(state, key, cx)
		local k = key.name
		if key.ctrl or key.alt or key.meta then
			-- ⌘⌫ / ⌃U clear the search, as in a text field.
			if (k == "backspace" and (key.meta or key.alt)) or (k == "u" and key.ctrl) then
				return search(state, "")
			end
			return false
		end
		if k == "escape" or k == "esc" then
			if state.query ~= "" then
				return search(state, "")
			end
			cx:open("agent-queue://unpick/")
			return false
		end
		if k == "backspace" then
			return search(state, picker.backspace(state.query))
		end
		local s = shown(state)
		local items = s.items
		local i = selection(state, items)
		if k == "enter" then
			if items[i] then
				cx:open("agent-queue://pick/" .. tostring(items[i].pane))
			end
			return false
		end
		local dir = ARROWS[k]
		if dir then
			if i == 0 then
				return false
			end
			local j = picker.move(i, grid(s, cx.cols), dir :: picker.Dir)
			if j == i then
				return false
			end
			state.selected, state.index = items[j].pane, j
			return true
		end
		-- Typed text (and paste, newlines dropped) goes into the search.
		local text = key.text
		if k == "space" then
			text = " "
		end
		if text and text ~= "" then
			text = string.gsub(text, "[%c]", " ")
			return search(state, state.query .. text)
		end
		return false
	end,

	event = forward,
}

tern.block.define("side", side)
tern.block.define("picker", pick)
