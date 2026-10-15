--!strict
-- Builds the canvas tree for the queue. Takes a plain model so the window
-- half decides what to show and this module only decides how.

local picker = require("./picker")

local ui = tern.ui

export type Item = {
	pane: number,
	state: string, -- "idle" | "waiting_input" | "working" | "done"
	skipped: boolean,
	title: string,
	where: string?, -- "session › tab"
	cwd: string?,
	branch: string?,
	task: string?,
	last_prompt: string?,
	loaded: boolean, -- context has been fetched (it may still be empty)
	now: string?, -- smol-model summary: the task it is on as of its latest turn
	status: string?, -- smol-model summary: what it just finished or reported
	summarizing: boolean,
	scene: string?, -- path of the session's illustrated scene, when one was generated
}

export type Model = {
	items: { Item }, -- head first
	current: Item?, -- the focused agent when queued or Done, else the one shown last, else the head
	running: { Item }, -- working agents, longest-running first
	done: { Item }, -- agents marked done, until they work again
	auto_advance: boolean,
	folded: { [string]: boolean }, -- list keys ("running", "done") folded to their heading
	compact: boolean, -- the canvas floats over the agent: show only what fits a small card
}

local M = {}

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function button(label: string, act: string, tone: string): Node
	return with(ui.badge(label, tone), { actions = { click = act }, title = label })
end

local function tilde(path: string): string
	local home = tern.getenv("HOME")
	if home and home ~= "" and string.sub(path, 1, #home) == home then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end

local function state_badge(item: Item): Node
	if item.state == "waiting_input" then
		return ui.badge(if item.skipped then "asked · skipped" else "needs input", "warning")
	elseif item.state == "working" then
		return ui.badge("running", "info")
	elseif item.state == "done" then
		return ui.badge("done", "muted")
	end
	return ui.badge("finished", "success")
end

-- Plain text clamped to `lines`, for the small floating card where markdown
-- blocks take too much room.
local function clamped(text: string, lines: number, style: string?): Node
	return with(ui.text({ ui.span(text, style) }), { lines = lines })
end

local function compact_card(item: Item, more: number, running: number): Node
	local where: { Span | string } = {}
	if item.cwd and item.cwd ~= "" then
		table.insert(where, ui.path(tilde(item.cwd), item.cwd))
	end
	if item.branch then
		table.insert(where, ui.span("  " .. item.branch, "code"))
	end

	-- A Done agent has nothing to skip or mark done.
	local head: { Node } = { state_badge(item), with(ui.row({}), { grow = 1 }) }
	if item.state ~= "done" then
		table.insert(head, button("Skip", "skip=" .. item.pane, "neutral"))
		table.insert(head, button("Done", "dismiss=" .. item.pane, "muted"))
	end
	local body: { Node } = { ui.row(head) }
	if #where > 0 then
		table.insert(body, with(ui.text(where), { truncate = "middle" }))
	end
	if item.now then
		table.insert(body, clamped(item.now, 3, "strong"))
		if item.status then
			table.insert(body, clamped(item.status, 2, "muted"))
		end
	elseif item.task then
		table.insert(body, clamped(item.task, 6))
	end
	if item.summarizing then
		table.insert(body, clamped("Summarizing…", 1, "muted"))
	end
	if item.last_prompt and item.last_prompt ~= item.task then
		table.insert(body, clamped("Last: " .. item.last_prompt, if item.now then 2 else 3, "muted"))
	end
	if not item.loaded then
		table.insert(body, clamped("Loading context…", 1, "muted"))
	end
	local counts: { string } = {}
	if more > 0 then
		table.insert(counts, string.format("%d more waiting", more))
	end
	if running > 0 then
		table.insert(counts, string.format("%d running", running))
	end
	if #counts > 0 then
		table.insert(body, clamped(table.concat(counts, " · "), 1, "muted"))
	end
	return with(ui.col(body), { key = "current", role = "agent-queue.compact" })
end

-- `image`: the scene's blob id, when the block resolved one (canvases can't
-- show images).
local function current_card(item: Item, image: string?): Node
	-- Folder and branch as plain lines (a label column costs a narrow pane
	-- its width).
	local place: { Node } = {}
	if item.cwd and item.cwd ~= "" then
		table.insert(place, with(ui.text({ ui.path(tilde(item.cwd), item.cwd) }), { truncate = "middle" }))
	end
	if item.branch then
		table.insert(place, with(ui.text({ ui.span(item.branch, "code") }), { truncate = "end" }))
	end

	-- The buttons, and a badge only when it asks, runs or is done (the card's
	-- tone says so too): "finished" beside three buttons doesn't fit a
	-- file-tree-wide pane. Skip and Done only apply to a queued agent (the
	-- card shows a Running or Done one when browsing the list).
	local queued = item.state == "idle" or item.state == "waiting_input"
	local actions: { Node } = {}
	if item.state == "waiting_input" and not item.skipped then
		table.insert(actions, ui.badge("asks", "warning"))
	elseif item.state == "working" then
		table.insert(actions, ui.badge("running", "info"))
	elseif item.state == "done" then
		table.insert(actions, ui.badge("done", "muted"))
	end
	table.insert(actions, with(ui.row({}), { grow = 1 }))
	table.insert(actions, button("Go to", "go=" .. item.pane, "accent"))
	if queued then
		table.insert(actions, button("Skip", "skip=" .. item.pane, "neutral"))
		table.insert(actions, button("Done", "dismiss=" .. item.pane, "muted"))
	end
	local body: { Node } = { ui.row(actions) }
	if #place > 0 then
		table.insert(body, ui.lines(place))
	end

	-- What it is on now, from the smol model: the card's only text. A label
	-- line over unindented text, not a section: sections indent, and a narrow
	-- pane can't spare it.
	if item.now then
		local label: { Span | string } = { ui.span("Now", "muted") }
		if item.summarizing then
			table.insert(label, ui.span("  summarizing…", "muted"))
		end
		local summary: { Node } = {
			ui.row({ ui.text(label), with(ui.row({}), { grow = 1 }), button("Refresh", "refresh=" .. item.pane, "neutral") }),
			ui.text({ ui.span(item.now, "strong") }),
		}
		table.insert(body, with(ui.lines(summary), { key = "now" }))
	elseif item.summarizing then
		table.insert(body, ui.text({ ui.span("Summarizing…", "muted") }))
	elseif not item.loaded then
		table.insert(body, ui.text({ ui.span("Loading context…", "muted") }))
	elseif item.last_prompt or item.task then
		-- No summary (summaries off, or omp failed): the prompt says something.
		table.insert(body, clamped(item.last_prompt or item.task :: string, 3, "muted"))
	else
		table.insert(body, ui.text({ ui.span("No conversation yet.", "muted") }))
	end

	-- The title opens the body rather than heading the card: a card indents
	-- its body under the heading, which a narrow pane can't spare. The scene,
	-- when there is one, tops the card: it is what tells agents apart at a
	-- glance.
	table.insert(body, 1, ui.text({ ui.span(item.title, "strong") }))
	if image then
		table.insert(body, 1, with(ui.node("image", { blob = image }), { key = "scene" }))
	end
	return with(ui.card({}, body), {
		key = "current",
		role = "agent-queue.current",
		tone = if item.state == "waiting_input" and not item.skipped
			then "warning"
			elseif item.state == "done" then "neutral"
			elseif item.state == "working" then "info"
			else "accent",
	})
end

-- The project's folder name, for an agent without a scene.
local function project_of(item: Item): string?
	return if item.cwd then string.match(item.cwd, "([^/]+)/*$") else nil
end

-- A row's icon: the agent's scene shrunk to a square, or (none drawn yet)
-- a square with the project's first letter.
local function thumb(item: Item, image: string?): Node
	if image then
		return with(ui.node("image", { blob = image }), { key = "thumb", role = "agent-queue.thumb" })
	end
	local project = project_of(item)
	local letter = if project then string.upper(string.match(project, utf8.charpattern) or "?") else "?"
	return with(ui.col({ ui.text({ ui.span(letter, "muted") }) }), { key = "thumb", role = "agent-queue.thumb-none" })
end

-- One agent of the lists. A block (`images` given) shows each with its scene
-- as an icon beside its title, which wraps to two lines, over where it is.
-- A canvas can't show images, so there each takes one line: the title,
-- then where it is (cut first). Only an agent asking a question gets a
-- badge; the list's heading says the rest.
local function queue_row(item: Item, is_current: boolean, prefix: string, images: { [string]: string }?): Node
	local asks = item.state == "waiting_input" and not item.skipped
	local children: { Node } = {}
	if images then
		local place: { Node } = {}
		if asks then
			table.insert(place, ui.badge("asks", "warning"))
		end
		if item.where then
			table.insert(place, with(ui.text({ ui.span(item.where, "muted") }), { grow = 1, truncate = "end" }))
		end
		local text: { Node } = { with(ui.text({ ui.span(item.title, if is_current then "strong" else nil) }), { lines = 2 }) }
		if #place > 0 then
			table.insert(text, ui.row(place))
		end
		table.insert(children, thumb(item, if item.scene then images[item.scene] else nil))
		table.insert(children, with(ui.lines(text), { grow = 1, role = "agent-queue.row-text" }))
	else
		local label: { Span | string } = { ui.span(item.title, if is_current then "strong" else nil) }
		if item.where then
			table.insert(label, ui.span("  " .. item.where, "muted"))
		end
		if asks then
			table.insert(children, ui.badge("asks", "warning"))
		end
		table.insert(children, with(ui.text(label), { grow = 1, truncate = "end" }))
	end
	return with(ui.row(children), {
		key = prefix .. item.pane,
		role = "agent-queue.row",
		actions = { click = "go=" .. item.pane },
		title = "Go to this agent",
	})
end

-- `images`: blob ids by scene path, which only a block can resolve.
function M.build(model: Model, images: { [string]: string }?): Node
	local children: { Node } = {}
	if model.compact then
		if model.current then
			local current = model.current :: Item
			local others = if current.state == "done" then #model.items else #model.items - 1
			table.insert(children, compact_card(current, others, #model.running))
		else
			table.insert(children, clamped("Nothing is waiting on you.", 1, "muted"))
		end
		return with(ui.col(children), { role = "agent-queue.root" })
	end

	if model.current then
		local current = model.current :: Item
		local image = if images and current.scene then images[current.scene] else nil
		table.insert(children, current_card(current, image))
	else
		table.insert(children, ui.text({ ui.span("Nothing is waiting on you.", "muted") }))
	end

	-- Each list is a heading line over unindented rows rather than a section,
	-- which indents its rows. Running and Done fold on a click on the heading
	-- (the window keeps which are folded).
	local function list(key: string, label: string, items: { Item }, prefix: string, foldable: boolean, current: number?)
		if #items == 0 then
			return
		end
		local folded = foldable and model.folded[key] == true
		local text = string.format("%s · %d", label, #items)
		if foldable then
			text = (if folded then "▸ " else "▾ ") .. text
		end
		local head = ui.text({ ui.span(text, "muted") })
		if foldable then
			head = with(head, { actions = { click = "fold=" .. key }, title = if folded then "Show" else "Hide" })
		end
		local lines: { Node } = { head }
		if not folded then
			for _, item in items do
				table.insert(lines, queue_row(item, item.pane == current, prefix, images))
			end
		end
		table.insert(children, with(ui.lines(lines), { key = key }))
	end
	list("queue", "Queue", model.items, "q", false, if model.current then model.current.pane else nil)
	list("running", "Running", model.running, "r", true, if model.current then model.current.pane else nil)
	list("done", "Done", model.done, "d", true, if model.current then model.current.pane else nil)

	return with(ui.col(children), { role = "agent-queue.root" })
end

-- A scene's stand-in when an agent has none (yet): the same 2:1 box,
-- showing the project's folder name.
local function no_scene(item: Item): Node
	local label = ui.text({ ui.span(project_of(item) or "no scene", "muted") })
	return with(ui.col({ label }), { key = "scene", role = "agent-queue.noscene" })
end

-- One card of the picker: scene (or its stand-in), title, where it is, and
-- what it is on. A badge says when it asks, runs or is done.
local function pick_card(item: Item, image: string?, selected: boolean): Node
	local asks = item.state == "waiting_input" and not item.skipped
	local head: { Node } = {}
	if asks then
		table.insert(head, ui.badge("asks", "warning"))
	elseif item.state == "working" then
		table.insert(head, ui.badge("running", "info"))
	elseif item.state == "done" then
		table.insert(head, ui.badge("done", "muted"))
	end
	table.insert(head, with(ui.text({ ui.span(item.title, "strong") }), { grow = 1, truncate = "end" }))
	local body: { Node } = {
		if image then with(ui.node("image", { blob = image }), { key = "scene" }) else no_scene(item),
		ui.row(head),
	}
	if item.where then
		table.insert(body, with(ui.text({ ui.span(item.where, "muted") }), { truncate = "end" }))
	end
	local about = item.now or item.last_prompt or item.task
	if about then
		table.insert(body, clamped(about, 2, if item.now then nil else "muted"))
	end
	return with(ui.card({}, body), {
		key = "p" .. item.pane,
		role = if selected then "agent-queue.pick.selected" else "agent-queue.pick",
		tone = if selected then "accent" elseif asks then "warning" else nil,
		actions = { click = "pick=" .. item.pane },
		title = "Go to this agent",
	})
end

export type PickerGroup = {
	label: string, -- "Waiting", "Running", "Done"
	items: { Item }, -- the ones the search matches
	total: number, -- matching or not
}

export type PickerView = {
	groups: { PickerGroup },
	items: { Item }, -- the groups' matching items in order: what indices count
	rows: { picker.Row }, -- rows of `items`
	query: string, -- the search as typed
	images: { [string]: string }, -- blob ids by scene path
	selected: number, -- index of the ringed card in `items` (0: none)
	per_row: number,
	top: number, -- first row shown
	last: number, -- last row shown
}

-- The picker: a search box over the matching agents, Waiting, Running and
-- Done each a heading over a grid of cards, `per_row` to a row, the
-- selected card ringed; rows `top` to `last` show.
function M.picker(p: PickerView): Node
	local keys: { Span | string } = {
		ui.span("←↑↓→", "key"),
		ui.span(" move  ", "muted"),
		ui.span("Enter", "key"),
		ui.span(" go  ", "muted"),
		ui.span("Esc", "key"),
		ui.span(if p.query ~= "" then " clear" else " close", "muted"),
	}
	-- The search box: what is typed, a caret, and a hint while empty. Keys
	-- reach it through the block's key handler (host.luau), not a native
	-- field, so arrows and Enter keep working on the grid.
	local field: { Span | string } = { ui.span("⌕ ", "muted") }
	if p.query ~= "" then
		table.insert(field, ui.span(p.query))
	end
	table.insert(field, ui.span("▏", "accent"))
	if p.query == "" then
		table.insert(field, ui.span("Type to search", "muted"))
	end
	local box = with(ui.text(field), { grow = 1, truncate = "start", role = "agent-queue.search" })

	local total = 0
	for _, g in p.groups do
		total += g.total
	end
	local head: { Span | string } = {}
	if p.query ~= "" then
		table.insert(head, ui.span(string.format("%d of %d", #p.items, total), "strong"))
	end
	if #p.rows > 0 and (p.top > 1 or p.last < #p.rows) then
		-- Rows out of view, above and below.
		table.insert(head, ui.span(string.format("  ↑%d ↓%d", p.top - 1, #p.rows - p.last), "muted"))
	end
	local children: { Node } = { ui.row({ box, ui.text(head), ui.text(keys) }) }
	if total == 0 then
		table.insert(children, ui.text({ ui.span("No omp agents.", "muted") }))
	elseif #p.items == 0 then
		table.insert(children, ui.text({ ui.span("No agent matches “" .. p.query .. "”.", "muted") }))
	end
	-- Each row is a CSS grid of `per_row` equal columns (the role names the
	-- count), so a short row keeps the card width. A group's heading tops its
	-- first row, and the top row shown.
	for r = p.top, p.last do
		local row = p.rows[r]
		if row.lead or r == p.top then
			local g = p.groups[row.group]
			local count = if p.query ~= "" then string.format("%d of %d", #g.items, g.total) else tostring(g.total)
			table.insert(children, with(ui.text({ ui.span(g.label .. " · " .. count, "muted") }), { key = "head" .. r }))
		end
		local cards: { Node } = {}
		for i = row.first, row.last do
			local item = p.items[i]
			local image = if item.scene then p.images[item.scene] else nil
			table.insert(cards, pick_card(item, image, i == p.selected))
		end
		table.insert(children, with(ui.row(cards), { key = "row" .. r, role = "agent-queue.pick-row." .. p.per_row }))
	end
	return with(ui.col(children), { role = "agent-queue.picker" })
end

function M.dock(model: Model): Node
	if model.compact then
		return ui.row({ button("Next", "next", "accent") })
	end
	return ui.row({
		button("Next", "next", "accent"),
		button(if model.auto_advance then "Auto-advance: on" else "Auto-advance: off", "auto", "neutral"),
	})
end

M.ABOUT = table.concat({
	"Agent queue: omp agents waiting on the user, oldest first; agents asking a question go first.",
	"Actions: go=<pane> focuses that agent; skip=<pane> moves it to the back; dismiss=<pane> hides it",
	"until it works again; next skips the focused agent and focuses the head; auto toggles auto-advance.",
}, " ")

return M
