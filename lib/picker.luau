--!strict
-- The picker's grid and search: cards laid out in groups (Waiting, Running,
-- Done), each starting its own rows under a heading; where an arrow key
-- moves the selection; how far to scroll; and which agents a query matches.
-- Pure Luau (no `tern` calls).

local M = {}

M.CARD_COLS = 40 -- a card's narrowest width, in cells
M.MAX_PER_ROW = 5
-- A card's height in cells: its 2:1 scene grows with its width (a cell is
-- about twice as tall as wide, so a quarter row per column), plus the title,
-- place, two summary lines, padding and the gap (measured, rounded up).
M.SCENE_ROWS_PER_COL = 0.25
M.TEXT_ROWS = 7
M.HEAD_ROWS = 3 -- the search line and the gaps around it
M.LEAD_ROWS = 2 -- a group's heading line and its gap

export type Dir = "left" | "right" | "up" | "down"

-- One row of cards: indices `first`..`last` of the flat list (groups in
-- order), in group `group`; `lead` when it is its group's first row.
export type Row = { first: number, last: number, group: number, lead: boolean }

-- Cards per row in a block `cols` cells wide.
function M.per_row(cols: number): number
	return math.clamp(cols // M.CARD_COLS, 1, M.MAX_PER_ROW)
end

-- A row of cards' height in cells, `per_row` to a row `cols` cells wide.
function M.card_rows(cols: number, per_row: number): number
	return math.ceil((cols / per_row) * M.SCENE_ROWS_PER_COL + M.TEXT_ROWS)
end

-- The rows of groups of `counts` cards, `per_row` to a row; empty groups
-- have none.
function M.rows(counts: { number }, per_row: number): { Row }
	local out: { Row } = {}
	local next_index = 1
	for group, count in counts do
		for first = next_index, next_index + count - 1, per_row do
			local last = math.min(first + per_row - 1, next_index + count - 1)
			table.insert(out, { first = first, last = last, group = group, lead = first == next_index })
		end
		next_index += count
	end
	return out
end

-- The row holding card `i`; 0 when none does.
function M.row_of(rows: { Row }, i: number): number
	for r, row in rows do
		if i >= row.first and i <= row.last then
			return r
		end
	end
	return 0
end

-- The last row shown when row `top` is the first, within `budget` cells: a
-- row costs `card_rows`, plus a heading when it leads its group or is the
-- top one (so the top row's group stays named). At least `top`.
function M.last_shown(rows: { Row }, top: number, budget: number, card_rows: number): number
	local used, last = 0, top
	for r = top, #rows do
		local cost = card_rows + (if rows[r].lead or r == top then M.LEAD_ROWS else 0)
		if used + cost > budget and r > top then
			break
		end
		used += cost
		last = r
	end
	return last
end

-- The first row to show so that row `row` is shown: `top` when it already
-- is, else scrolled just far enough; and never so far that space is left
-- empty below the last row.
function M.scroll(rows: { Row }, top: number, row: number, budget: number, card_rows: number): number
	if #rows == 0 then
		return 1
	end
	top = math.clamp(top, 1, #rows)
	while top > 1 and M.last_shown(rows, top - 1, budget, card_rows) >= #rows do
		top -= 1
	end
	if row < top then
		return math.max(row, 1)
	end
	while top < row and M.last_shown(rows, top, budget, card_rows) < row do
		top += 1
	end
	return top
end

-- The card the selection moves to from card `i`. Left and right run on
-- through the flat list; up and down go to the row above or below (across
-- groups) in the same column, or that row's last card when it is shorter.
-- Stays put at the edges.
function M.move(i: number, rows: { Row }, dir: Dir): number
	if #rows == 0 then
		return i
	end
	local count = rows[#rows].last
	i = math.clamp(i, 1, count)
	if dir == "left" then
		return math.max(i - 1, 1)
	elseif dir == "right" then
		return math.min(i + 1, count)
	end
	local r = M.row_of(rows, i)
	local target = if dir == "up" then r - 1 else r + 1
	if target < 1 or target > #rows then
		return i
	end
	return math.min(rows[target].first + (i - rows[r].first), rows[target].last)
end

-- Whether every word of `query` appears in one of `fields`, ignoring case.
-- An empty query matches everything.
function M.matches(fields: { string }, query: string): boolean
	local text = string.lower(table.concat(fields, "\n"))
	for word in string.gmatch(string.lower(query), "%S+") do
		if not string.find(text, word, 1, true) then
			return false
		end
	end
	return true
end

-- `query` without its last character (UTF-8 aware).
function M.backspace(query: string): string
	local n = utf8.len(query)
	if n == nil or n == 0 then
		return ""
	end
	local last = utf8.offset(query, n) :: number
	return string.sub(query, 1, last - 1)
end

return M
