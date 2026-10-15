--!strict
-- Tests for the pure rules in lib/queue.luau, lib/summary.luau,
-- lib/layout.luau and lib/picker.luau.
-- Run from the plugin directory: luau tests/run.luau

local queue = require("../lib/queue")
local summary = require("../lib/summary")
local layout = require("../lib/layout")
local picker = require("../lib/picker")

local failures = 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn :: any)
	if not ok then
		failures += 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end

local function eq(actual: any, expected: any, what: string?)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
	end
end

local function order(store: queue.Store): string
	local panes: { string } = {}
	for _, e in queue.ordered(store) do
		table.insert(panes, tostring(e.pane))
	end
	return table.concat(panes, ",")
end

local function entry(store: queue.Store, pane: number): queue.Entry
	local e = queue.get(store, pane)
	assert(e, "pane " .. pane .. " not queued")
	return e
end

local function idle(pane: number, turn: string?): queue.AgentState
	return { pane = pane, state = "idle", turn = turn }
end

local function asking(pane: number, turn: string?): queue.AgentState
	return { pane = pane, state = "waiting_input", turn = turn }
end

-- Queue ------------------------------------------------------------------------

test("agents queue in the order they stop working", function()
	local s = queue.new()
	queue.reconcile(s, { idle(2, "b") }, 0)
	queue.reconcile(s, { idle(2, "b"), idle(1, "a") }, 1)
	eq(order(s), "2,1")
end)

test("an agent asking a question goes ahead of finished ones", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), idle(2, "b"), asking(3, "c") }, 0)
	eq(order(s), "3,1,2")
	local total, n = queue.counts(s)
	eq(total, 3, "total")
	eq(n, 1, "asking")
end)

test("an unchanged poll changes nothing", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), asking(2, "b") }, 0)
	local changed, entered, left = queue.reconcile(s, { idle(1, "a"), asking(2, "b") }, 100)
	eq(changed, false, "changed")
	eq(#entered + #left, 0, "moves")
end)

test("working leaves the queue at once; a closed agent after the grace period", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), idle(2, "b"), idle(3, "c") }, 0)
	local changed, _, left = queue.reconcile(s, { { pane = 1, state = "working" }, idle(3, "c") }, 1)
	eq(changed, true, "changed")
	eq(table.concat(left, ","), "1", "left")
	eq(order(s), "3", "closed agent hidden")
	local _, _, later = queue.reconcile(s, { idle(3, "c") }, 1 + 600)
	eq(table.concat(later, ","), "2", "left after the grace period")
	eq(s.entries["2"], nil, "entry dropped")
end)

test("agents dropping out of the list briefly keep their place and Done marks", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), idle(2, "b"), idle(3, "c") }, 0)
	queue.dismiss(s, 2)
	queue.skip(s, 1)
	-- The daemon detaches: nothing listed, or listed as exited.
	queue.reconcile(s, {}, 100)
	queue.reconcile(s, { { pane = 3, state = "exited" } }, 101)
	eq(order(s), "", "hidden while gone")
	eq(#queue.dismissed(s), 0, "done list hidden too")
	eq(queue.get(s, 1), nil, "get")
	local _, entered = queue.reconcile(s, { idle(1, "a"), idle(2, "b"), idle(3, "c") }, 103)
	eq(#entered, 0, "nothing re-entered")
	eq(order(s), "3,1", "order kept")
	eq(#queue.dismissed(s), 1, "Done kept")
end)

test("an agent coming back after the grace period is new", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a") }, 0)
	queue.dismiss(s, 1)
	queue.reconcile(s, {}, 10)
	queue.reconcile(s, {}, 10 + 600)
	queue.reconcile(s, { idle(1, "a") }, 700)
	eq(order(s), "1")
end)

test("finishing again after a seen turn rejoins at the back", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), idle(2, "b") }, 0)
	queue.reconcile(s, { { pane = 1, state = "working" }, idle(2, "b") }, 5)
	queue.reconcile(s, { idle(1, "a2"), idle(2, "b") }, 30)
	eq(order(s), "2,1")
	eq(entry(s, 1).since, 30, "since")
end)

test("a missed turn (new last message) rejoins at the back", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), idle(2, "b") }, 0)
	local _, entered = queue.reconcile(s, { idle(1, "a2"), idle(2, "b") }, 60)
	eq(order(s), "2,1")
	eq(entered[1], 1, "entered")
	eq(entry(s, 1).since, 60, "since")
end)

test("a last message changing within the grace period keeps the place and drops context", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "stale"), idle(2, "b") }, 0)
	entry(s, 1).ctx = { task = "read too early" }
	queue.reconcile(s, { idle(1, "fresh"), idle(2, "b") }, 7)
	eq(order(s), "1,2")
	eq(entry(s, 1).turn, "fresh", "turn")
	eq(entry(s, 1).ctx, nil, "ctx")
	-- Its next turn, past the grace period, counts.
	queue.reconcile(s, { idle(1, "next"), idle(2, "b") }, 60)
	eq(order(s), "2,1")
end)

test("a first last message keeps the place and drops context, however late", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1), idle(2, "b") }, 0)
	entry(s, 1).ctx = {}
	queue.reconcile(s, { idle(1, "hi"), idle(2, "b") }, 600)
	eq(order(s), "1,2")
	eq(entry(s, 1).ctx, nil, "ctx")
end)

test("a last message going unknown is not a turn", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), idle(2, "b") }, 0)
	local changed = queue.reconcile(s, { idle(1), idle(2, "b") }, 60)
	eq(changed, false, "changed")
	eq(entry(s, 1).turn, "a", "turn")
end)

test("a new question rejoins with priority, even within the grace period", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), idle(2, "b") }, 0)
	queue.reconcile(s, { idle(1, "a"), asking(2, "b") }, 3)
	eq(order(s), "2,1")
end)

test("answering a question rejoins at the back without priority", function()
	local s = queue.new()
	queue.reconcile(s, { asking(1, "q"), idle(2, "b") }, 0)
	eq(order(s), "1,2")
	queue.reconcile(s, { idle(1, "q"), idle(2, "b") }, 2)
	eq(order(s), "2,1")
	local _, n = queue.counts(s)
	eq(n, 0, "asking")
end)

test("skip moves to the back and drops question priority until a new question", function()
	local s = queue.new()
	queue.reconcile(s, { asking(1, "q"), idle(2, "b"), idle(3, "c") }, 0)
	eq(queue.skip(s, 1), true, "skipped")
	eq(order(s), "2,3,1")
	local _, n = queue.counts(s)
	eq(n, 0, "asking after skip")
	queue.reconcile(s, { asking(1, "q"), idle(2, "b"), idle(3, "c") }, 60)
	eq(order(s), "2,3,1", "same question keeps the skip")
	queue.reconcile(s, { asking(1, "q2"), idle(2, "b"), idle(3, "c") }, 61)
	eq(order(s), "1,2,3", "new question")
end)

test("done hides an agent until it works again", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), idle(2, "b") }, 0)
	eq(queue.dismiss(s, 1), true, "dismissed")
	eq(order(s), "2")
	eq(queue.get(s, 1), nil, "get")
	eq(#queue.dismissed(s), 1, "done list")
	eq(queue.skip(s, 1), false, "skip a done agent")
	queue.reconcile(s, { idle(1, "a"), idle(2, "b") }, 30)
	eq(order(s), "2", "still hidden")
	queue.reconcile(s, { idle(1, "a2"), idle(2, "b") }, 60)
	eq(order(s), "2,1", "back after a missed turn")
	eq(#queue.dismissed(s), 0, "done list")
end)

test("advance skips the focused agent and returns the next", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a"), idle(2, "b"), idle(3, "c") }, 0)
	eq(queue.advance(s, 1), 2, "next")
	eq(order(s), "2,3,1")
	eq(queue.advance(s, 99), 2, "focused not queued")
	eq(order(s), "2,3,1", "unqueued focus moves nothing")
end)

test("advance returns nil when only the focused agent waits", function()
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a") }, 0)
	eq(queue.advance(s, 1), nil)
	eq(queue.advance(queue.new(), nil), nil, "empty")
end)

test("coerce starts fresh from malformed data and keeps a valid store", function()
	eq(queue.coerce(nil).seq, 0, "nil")
	eq(queue.coerce({ entries = "x", seq = 3 }).seq, 0, "bad entries")
	eq(queue.coerce({ entries = {}, seq = "3" }).seq, 0, "bad seq")
	local s = queue.new()
	queue.reconcile(s, { idle(1, "a") }, 0)
	eq(queue.coerce(s), s, "valid")
end)

local function saved(seq: number, panes: { number }): any
	local entries: { [string]: any } = {}
	for _, p in panes do
		entries[tostring(p)] = { pane = p, seq = 1, since = 0, state = "idle" }
	end
	return { entries = entries, seq = seq }
end

local function live(panes: { number }): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, p in panes do
		out[tostring(p)] = true
	end
	return out
end

test("adopt picks the saved store sharing the most live agents", function()
	local key = queue.adopt({
		["store:a"] = saved(100, { 1, 2 }),
		["store:b"] = saved(5, { 1, 2, 3, 9 }),
		["store:other window"] = saved(500, { 70, 71 }),
	}, live({ 1, 2, 3 }))
	eq(key, "store:b")
end)

test("adopt breaks a tie by the longer history", function()
	local key = queue.adopt({
		["store:fresh"] = saved(10, { 1, 2 }),
		["store:old"] = saved(106, { 1, 2 }),
	}, live({ 1, 2 }))
	eq(key, "store:old")
end)

test("adopt finds nothing when no saved store shares an agent", function()
	eq(queue.adopt({ ["store:x"] = saved(9, { 70 }), ["store:bad"] = { entries = "?" } }, live({ 1 })), nil, "no overlap")
	eq(queue.adopt({}, live({ 1 })), nil, "no stores")
end)

-- Summary ----------------------------------------------------------------------

local function msg(role: string, text: string, tools: { { [string]: any } }?): summary.Message
	return { role = role, text = text, tools = tools or {} } :: any
end

test("fingerprint changes with the conversation and only then", function()
	local a = { msg("user", "fix it"), msg("assistant", "fixed") }
	local b = { msg("user", "fix it"), msg("assistant", "fixed") }
	eq(summary.fingerprint(a), summary.fingerprint(b), "same")
	table.insert(b, msg("user", "now test it"))
	if summary.fingerprint(a) == summary.fingerprint(b) then
		error("new message kept the fingerprint")
	end
end)

test("prompt keeps the newest messages, oldest first, within the input cap", function()
	local messages: { summary.Message } = {}
	for i = 1, 30 do
		table.insert(messages, msg(if i % 2 == 1 then "user" else "assistant", "message " .. i))
	end
	local p = summary.prompt(messages, nil, nil)
	eq(string.find(p, "message 10\n", 1, true), nil, "older than the last 20")
	local first = string.find(p, "[user] message 11", 1, true)
	local last = string.find(p, "[assistant] message 30", 1, true)
	if first == nil or last == nil or first > last then
		error("expected messages 11..30 oldest first")
	end

	local long: { summary.Message } = {}
	for i = 1, 20 do
		table.insert(long, msg("user", string.format("%02d ", i) .. string.rep("x", 700)))
	end
	local q = summary.prompt(long, nil, nil)
	if string.find(q, "[user] 20 ", 1, true) == nil then
		error("newest message dropped")
	end
	eq(string.find(q, "[user] 01 ", 1, true), nil, "oldest kept past the cap")
	if #q > summary.INPUT_CLIP + 1000 then
		error("prompt over the cap: " .. #q)
	end
end)

test("prompt clips long messages to head and tail on character boundaries", function()
	local text = "START " .. string.rep("é", 2000) .. " END"
	local p = summary.prompt({ msg("assistant", text) }, nil, nil)
	if string.find(p, "START", 1, true) == nil or string.find(p, "END", 1, true) == nil then
		error("head or tail lost")
	end
	if string.find(p, " … ", 1, true) == nil then
		error("no elision mark")
	end
	if utf8.len(p) == nil then
		error("clipped mid-character")
	end
end)

test("prompt lists tool names once and skips empty turns", function()
	local p = summary.prompt({
		msg("assistant", "", { { name = "read" }, { name = "edit" }, { name = "read" } }),
		msg("assistant", "   "),
	}, nil, nil)
	if string.find(p, "(tools: read, edit)", 1, true) == nil then
		error("tool names: " .. p)
	end
	local _, n = string.gsub(p, "%[assistant%]", "")
	eq(n, 1, "assistant lines")
end)

test("prompt carries the previous summary and first request", function()
	local p = summary.prompt({ msg("user", "go") }, { now = "Fix login", status = "tests pass", at = 0, fingerprint = "" }, "Build auth")
	if string.find(p, "now: Fix login", 1, true) == nil or string.find(p, "Build auth", 1, true) == nil then
		error(p)
	end
	if string.find(summary.prompt({ msg("user", "go") }, nil, nil), "Previous summary: none.", 1, true) == nil then
		error("no previous marker")
	end
end)

-- tern.json.decode stand-in: the JSON objects these tests feed parse.
local DECODED: { [string]: any } = {
	['{"now": "Fix login", "status": "tests pass"}'] = { now = "Fix login", status = "tests pass" },
	['{"now": "", "status": "x"}'] = { now = "", status = "x" },
	['{"now": "Ship it", "status": ""}'] = { now = "Ship it", status = "" },
}
local function decode(s: string): any
	local v = DECODED[s]
	if v == nil then
		error("invalid JSON")
	end
	return v
end

test("parse reads the JSON object out of surrounding text", function()
	local r = summary.parse('Sure:\n{"now": "Fix login", "status": "tests pass"}\n', decode)
	assert(r)
	eq(r.now, "Fix login", "now")
	eq(r.status, "tests pass", "status")
end)

test("parse drops an empty status", function()
	local r = summary.parse('{"now": "Ship it", "status": ""}', decode)
	assert(r)
	eq(r.status, nil, "status")
end)

test("parse falls back to the first meaningful line", function()
	local r = summary.parse("\nWorking...\n  Refactor the parser  \n{broken}", decode)
	assert(r)
	eq(r.now, "Refactor the parser", "invalid JSON")
	local e = summary.parse('{"now": "", "status": "x"}', decode)
	assert(e)
	eq(e.now, '{"now": "", "status": "x"}', "empty now")
	eq(summary.parse("  \n\n", decode), nil, "blank")
end)

test("parse clips a long now", function()
	local r = summary.parse(string.rep("word ", 100), decode)
	assert(r)
	eq(utf8.len(r.now), 161, "160 characters and an ellipsis")
end)

-- Picker -------------------------------------------------------------------------

test("picker arrows move through a grid with a short last row", function()
	-- 7 cards, 3 to a row: 1 2 3 / 4 5 6 / 7
	local rows = picker.rows({ 7 }, 3)
	eq(picker.move(2, rows, "down"), 5, "down keeps the column")
	eq(picker.move(5, rows, "down"), 7, "down onto a short row lands on its last card")
	eq(picker.move(7, rows, "down"), 7, "down from the last row stays")
	eq(picker.move(7, rows, "up"), 4, "up keeps the column")
	eq(picker.move(2, rows, "up"), 2, "up from the first row stays")
	eq(picker.move(3, rows, "right"), 4, "right runs on to the next row")
	eq(picker.move(7, rows, "right"), 7, "right from the last card stays")
	eq(picker.move(1, rows, "left"), 1, "left from the first card stays")
	eq(picker.move(9, rows, "left"), 6, "a stale index is clamped first")
end)

test("picker groups start their own rows and arrows cross them", function()
	-- Waiting 2, Running 0, Done 4, 3 to a row: [1 2] / [3 4 5] [6]
	local rows = picker.rows({ 2, 0, 4 }, 3)
	eq(#rows, 3, "rows")
	eq(rows[2].first, 3, "Done starts a new row")
	eq(rows[2].group, 3, "empty Running has no rows")
	eq(rows[2].lead and not rows[3].lead, true, "only a group's first row leads")
	eq(picker.move(2, rows, "down"), 4, "down into the next group keeps the column")
	eq(picker.move(5, rows, "up"), 2, "up onto a short row lands on its last card")
	eq(picker.move(2, rows, "right"), 3, "right runs on into the next group")
end)

test("picker scrolls just enough to show the selected row", function()
	-- 4 rows in one group; a row costs 10, a heading 2: 22 shows two rows.
	local rows = picker.rows({ 12 }, 3)
	eq(picker.last_shown(rows, 1, 22, 10), 2, "lead heading and two rows")
	eq(picker.last_shown(rows, 2, 22, 10), 3, "the top row gets a heading too")
	eq(picker.last_shown(rows, 1, 5, 10), 1, "the top row shows even when it doesn't fit")
	eq(picker.scroll(rows, 1, 2, 22, 10), 1, "a shown row keeps the top")
	eq(picker.scroll(rows, 1, 4, 22, 10), 3, "down: the row lands at the bottom")
	eq(picker.scroll(rows, 3, 1, 22, 10), 1, "up: the row lands at the top")
	eq(picker.scroll(rows, 4, 4, 100, 10), 1, "no empty space below the last row")
end)

test("picker rows hold one card up to the most a row takes", function()
	eq(picker.per_row(20), 1, "narrower than a card")
	eq(picker.per_row(picker.CARD_COLS * 2 + 5), 2)
	eq(picker.per_row(400), picker.MAX_PER_ROW)
end)

test("picker search needs every word, in any field, any case", function()
	local fields = { "DOCS: Write the install guide", "docs site › tab 1", "/Users/me/git/website" }
	eq(picker.matches(fields, ""), true, "empty query")
	eq(picker.matches(fields, "  "), true, "blank query")
	eq(picker.matches(fields, "guide WEBSITE"), true, "words from different fields")
	eq(picker.matches(fields, "guide video"), false, "one word missing")
	eq(picker.matches(fields, "tab 1"), true, "words in place text")
	eq(picker.matches(fields, "1/users"), false, "a word can't span two fields")
	eq(picker.matches(fields, "a.b"), false, "punctuation is literal, not a pattern")
end)

test("picker backspace drops one whole character", function()
	eq(picker.backspace("abc"), "ab")
	eq(picker.backspace("café"), "caf", "multibyte last character")
	eq(picker.backspace(""), "", "empty stays empty")
end)

-- Layout --------------------------------------------------------------------------

local function leaf(id: number): any
	return { Leaf = id }
end

local function split(axis: string, ratio: number, a: any, b: any): any
	return { Split = { axis = axis, ratio = ratio, a = a, b = b } }
end

local function inspected(blocks: { any }, splits: any): any
	return { sessions = { { tabs = { { blocks = { { id = 1, program = "/bin/zsh", cols = 999 } }, splits = leaf(1) }, { blocks = blocks, splits = splits } } } } }
end

local function near(actual: number?, expected: number, what: string)
	if actual == nil or math.abs(actual - expected) > 0.5 then
		error(string.format("%s: expected about %s, got %s", what, tostring(expected), tostring(actual)), 2)
	end
end

test("split_cols: canvas beside its agent in the left half of a tab", function()
	-- [ [canvas | agent] | file viewer ]: the agent's 152 columns at 0.447 of
	-- the tab make it 340 wide, and the canvas's split is half of that.
	local data = inspected({
		{ id = 10, program = "tern.canvas", cols = 15 },
		{ id = 11, program = "/bin/zsh", cols = 152 },
		{ id = 12, program = "", cols = 0 },
	}, split("Row", 0.5, split("Row", 0.10547249, leaf(10), leaf(11)), leaf(12)))
	near(layout.split_cols(data, 10), 169.9, "split")
end)

test("split_cols: nested splits, stacked panes keep their width", function()
	-- The widest terminal (outer right, 0.3768 of the tab) sets the tab's width;
	-- the stacked panes don't narrow anything.
	local data = inspected({
		{ id = 20, program = "tern.canvas", cols = 8 },
		{ id = 21, program = "/bin/zsh", cols = 28 },
		{ id = 22, program = "/bin/zsh", cols = 106 },
		{ id = 23, program = "/bin/zsh", cols = 106 },
		{ id = 24, program = "/bin/zsh", cols = 128 },
	}, split(
		"Row",
		0.6231929,
		split("Row", 0.5, split("Row", 0.2664086, leaf(20), leaf(21)), split("Column", 0.5, leaf(22), leaf(23))),
		leaf(24)
	))
	near(layout.split_cols(data, 20), 128 / (1 - 0.6231929) * 0.6231929 * 0.5, "split")
end)

test("split_cols: nil when nothing is right of the canvas or no terminal measures the tab", function()
	local right_side = inspected({
		{ id = 30, program = "/bin/zsh", cols = 100 },
		{ id = 31, program = "tern.canvas", cols = 30 },
	}, split("Row", 0.7, leaf(30), leaf(31)))
	eq(layout.split_cols(right_side, 31), nil, "canvas on the right")
	local no_terminal = inspected({
		{ id = 40, program = "tern.canvas", cols = 30 },
		{ id = 41, program = "", cols = 0 },
	}, split("Row", 0.2, leaf(40), leaf(41)))
	eq(layout.split_cols(no_terminal, 40), nil, "no terminal")
	eq(layout.split_cols(right_side, 99), nil, "unknown canvas")
	eq(layout.split_cols(nil, 31), nil, "no data")
end)

if failures > 0 then
	error(string.format("%d test(s) failed", failures), 0)
end
print("all tests passed")
