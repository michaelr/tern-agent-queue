--!strict
-- Pane widths from `tern inspect --json`. Plugins see split ratios but no
-- pane widths; inspect reports each terminal's columns and every tab's split
-- tree. Pure Luau (no `tern` calls).

local M = {}

-- Width in columns of the split that puts a divider on the canvas's right
-- (the nearest side-by-side split with the canvas on its first side), in
-- `inspect` as decoded from `tern inspect --json`. A terminal's columns over
-- its share of the tab give the tab's width (the widest terminal, for
-- accuracy); the split's share of the tab then gives its width. Nil when the
-- canvas, such a split or a terminal in its tab can't be found.
function M.split_cols(inspect: any, canvas: number): number?
	if type(inspect) ~= "table" then
		return nil
	end
	for _, s in (inspect.sessions or {}) :: { any } do
		for _, t in (s.tabs or {}) :: { any } do
			local in_tab = false
			for _, b in (t.blocks or {}) :: { any } do
				in_tab = in_tab or b.id == canvas
			end
			if in_tab and t.splits then
				-- Each leaf's share of the tab's width; side-by-side splits
				-- have axis "Row".
				local shares: { [number]: number } = {}
				local split_share: number? = nil
				local function walk(node: any, share: number): boolean
					if node.Leaf ~= nil then
						shares[node.Leaf] = share
						return node.Leaf == canvas
					end
					local sp = node.Split
					if sp == nil then
						return false
					end
					local row = sp.axis == "Row"
					local ratio = if type(sp.ratio) == "number" then sp.ratio else 0.5
					local in_a = walk(sp.a, if row then share * ratio else share)
					local in_b = walk(sp.b, if row then share * (1 - ratio) else share)
					if in_a and row and split_share == nil then
						split_share = share
					end
					return in_a or in_b
				end
				walk(t.splits, 1)
				local tab_cols: number? = nil
				local best = 0
				for _, b in (t.blocks or {}) :: { any } do
					local share = shares[b.id]
					local terminal = b.id ~= canvas and type(b.program) == "string" and b.program ~= "" and b.program ~= "tern.canvas"
					if terminal and share and share > best and type(b.cols) == "number" and b.cols > 0 then
						best, tab_cols = share, b.cols / share
					end
				end
				if tab_cols and split_share then
					return tab_cols * split_share
				end
				return nil
			end
		end
	end
	return nil
end

return M
