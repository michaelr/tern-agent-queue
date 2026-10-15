--!strict
-- Prompt building and output parsing for the rolling "current task" summary.
-- Pure Luau (no `tern` calls); window.luau runs `omp -p` with the result.

local queue = require("./queue")

export type Message = AgentMessage -- Tern's transcript message: role, text, tools
export type Parsed = { now: string, status: string? }

local M = {}

M.RECENT_MESSAGES = 20 -- the tail the model reads
M.MESSAGE_CLIP = 600 -- characters per message
M.INPUT_CLIP = 8000 -- characters of conversation in total

M.SYSTEM_PROMPT = table.concat({
	"You summarize a coding agent's session for a dashboard the user glances at",
	"when returning to it. Reply with one JSON object and nothing else, no code fence:",
	'{"now": string, "status": string}.',
	'"now": the task the agent is on as of its latest turn, imperative, at most 12 words.',
	"Sessions drift: judge from the recent conversation, not the first request.",
	'"status": what the agent just finished or reported, at most 14 words.',
}, " ")

local function clip(s: string, n: number): string
	local trimmed = string.match(s, "^%s*(.-)%s*$") or s
	if #trimmed <= n then
		return trimmed
	end
	local cut = utf8.offset(trimmed, n + 1)
	if cut == nil then
		return trimmed
	end
	return string.sub(trimmed, 1, cut - 1) .. "…"
end

-- Keeps the head and tail of a long message: a reply's conclusion is usually
-- at its end, its framing at its start. Cuts on character boundaries.
local function clip_middle(s: string, n: number): string
	local trimmed = string.match(s, "^%s*(.-)%s*$") or s
	local chars = utf8.len(trimmed)
	if chars == nil or chars <= n then
		return if chars == nil then clip(trimmed, n) else trimmed
	end
	local half = n // 2
	local head_end = (utf8.offset(trimmed, half + 1) :: number) - 1
	local tail_start = utf8.offset(trimmed, chars - half + 1) :: number
	return string.sub(trimmed, 1, head_end) .. " … " .. string.sub(trimmed, tail_start)
end

local function tool_names(m: Message): string?
	if m.tools == nil or #m.tools == 0 then
		return nil
	end
	local names: { string } = {}
	for _, t in m.tools do
		local name = t.name
		if type(name) == "string" and not table.find(names, name) then
			table.insert(names, name)
		end
	end
	return if #names > 0 then table.concat(names, ", ") else nil
end

-- What identifies the conversation as summarized: unchanged means no re-run.
function M.fingerprint(messages: { Message }): string
	local last_user, last_assistant = "", ""
	for _, m in messages do
		if m.role == "user" then
			last_user = m.text
		elseif m.role == "assistant" then
			last_assistant = m.text
		end
	end
	return string.format("%d|%d:%s|%d:%s", #messages, #last_user, string.sub(last_user, -60), #last_assistant, string.sub(last_assistant, -60))
end

-- The user message for `omp -p`: previous summary, the first request, and
-- the recent conversation (oldest first, newest kept when over the cap).
function M.prompt(messages: { Message }, previous: queue.Summary?, first: string?): string
	local lines: { string } = {}
	local total = 0
	for i = #messages, math.max(1, #messages - M.RECENT_MESSAGES + 1), -1 do
		local m = messages[i]
		local tools = tool_names(m)
		local body = clip_middle(m.text, M.MESSAGE_CLIP)
		if body == "" and tools == nil then
			continue
		end
		local line = string.format("[%s] %s%s", m.role, body, if tools then " (tools: " .. tools .. ")" else "")
		if total + #line > M.INPUT_CLIP then
			break
		end
		total += #line
		table.insert(lines, 1, line)
	end

	local parts: { string } = {}
	if previous then
		table.insert(parts, "Previous summary (may be stale):\nnow: " .. previous.now .. "\nstatus: " .. (previous.status or ""))
	else
		table.insert(parts, "Previous summary: none.")
	end
	if first and first ~= "" then
		table.insert(parts, "First request in this session:\n" .. clip(first, M.MESSAGE_CLIP))
	end
	table.insert(parts, "Recent conversation, oldest first:\n" .. table.concat(lines, "\n"))
	table.insert(parts, "Reply with the JSON object only.")
	return table.concat(parts, "\n\n")
end

-- Reads the model's answer: the first {...} decoded as JSON, else its first
-- non-blank line as `now`. `decode` is tern.json.decode (injected for tests).
function M.parse(output: string, decode: (string) -> any): Parsed?
	local object = string.match(output, "%b{}")
	if object then
		local ok, value = pcall(decode, object)
		if ok and type(value) == "table" and type(value.now) == "string" and value.now ~= "" then
			return {
				now = clip(value.now, 160),
				status = if type(value.status) == "string" and value.status ~= "" then clip(value.status, 200) else nil,
			}
		end
	end
	for line in string.gmatch(output, "[^\n]+") do
		local text = string.match(line, "^%s*(.-)%s*$") or ""
		if text ~= "" and text ~= "Working..." then
			return { now = clip(text, 160) }
		end
	end
	return nil
end

return M
