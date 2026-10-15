--!strict
-- TEMPORARY: times agent-queue's timer callbacks and their slow parts into
-- tern.log (warn level) to find what trips Tern's 50 ms timer budget (seen
-- 2026-10-13 18:17:40). Remove once found.
--
--   tern.timer(0, timing.hook("timer render", function(cx) ... end))
--   local agents = timing.part("agents:list", function() return cx.agents:list() end)
--
-- A hook logs `aq-timing <hook> <total>ms | <part>=<ms> …` when it takes MIN_MS
-- or more. A budget overrun ends the call without unwinding, so the call that
-- trips is not logged itself: look for the same hook running close to 50 ms.

local MIN_MS = 25

type Record = { start: number, parts: { string } }

local current: Record? = nil

local function note(label: string, ms: number)
	local rec = current
	if rec ~= nil then
		table.insert(rec.parts, string.format("%s=%.1f", label, ms))
	end
end

local function part(label: string, fn: () -> ...any): ...any
	local start = tern.now()
	local results = table.pack(fn())
	note(label, tern.now() - start)
	return table.unpack(results, 1, results.n)
end

local function hook(name: string, fn: (...any) -> ...any): (...any) -> ...any
	return function(...: any): ...any
		local outer = current
		local rec: Record = { start = tern.now(), parts = {} }
		current = rec
		local results = table.pack(pcall(fn, ...))
		current = outer
		local took = tern.now() - rec.start
		local ok = results[1]
		if not ok or took >= MIN_MS then
			tern.log.warn(string.format(
				"aq-timing %s %.1fms%s | %s",
				name,
				took,
				if ok then "" else " RAISED " .. tostring(results[2]),
				table.concat(rec.parts, " ")
			))
		end
		if not ok then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end
end

return {
	note = note,
	part = part,
	hook = hook,
}
