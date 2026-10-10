-- Session picker. With snacks.nvim, the preview shows the most recent
-- inputs of the highlighted session (the `history` method); without
-- it, falls back to vim.ui.select.

local discover = require("replconnect.discover")
local languages = require("replconnect.languages")
local socket = require("replconnect.socket")

local M = {}

M.HISTORY_LIMIT = 10

---Prompt and preview filetype for a session's language.
---@param info table discovery record
---@return string prompt
---@return string? filetype
function M.style(info)
	local language = languages.get(discover.language(info))
	if not language then
		return "> ", nil
	end
	return language.prompt, language.filetypes[1]
end

---REPL-style lines for `history` entries (oldest first).
---@param entries { input: string }[]
---@param prompt? string shown before each input (default "> ")
---@return string[]
function M.transcript(entries, prompt)
	prompt = prompt or "> "
	if #entries == 0 then
		return { "# no evaluations yet" }
	end
	local indent = (" "):rep(vim.fn.strdisplaywidth(prompt))
	local lines = {}
	for _, entry in ipairs(entries) do
		for j, line in ipairs(vim.split(entry.input, "\n", { plain = true })) do
			lines[#lines + 1] = (j == 1 and prompt or indent) .. line
		end
	end
	return lines
end

---Fetch a session's transcript over a short-lived connection.
---@param info table discovery record
---@param callback fun(lines: string[])
function M.fetch(info, callback)
	socket.connect(info.socket, { client = "replconnect.nvim (picker)", timeout_ms = 2000 }, function(err, client)
		if err then
			return callback({ "# " .. err })
		end
		if not vim.tbl_contains(client.info.capabilities or {}, "history") then
			client:close()
			return callback({
				"# no preview: this session does not advertise input history",
				"# history recording may be disabled, or the service may be older",
			})
		end
		client:request("history", { limit = M.HISTORY_LIMIT }, function(result)
			client:close()
			callback(M.transcript(result.entries or {}, (M.style(info))))
		end, function(e)
			client:close()
			callback({ "# history unavailable: " .. tostring(e.message) })
		end)
	end)
end

local function snacks_select(Snacks, sessions, on_choice)
	local transcripts = {}
	local items = vim.tbl_map(function(info)
		return { text = discover.label(info), session = info }
	end, sessions)

	local function show(ctx)
		ctx.preview:reset()
		ctx.preview:set_title("pid " .. ctx.item.session.pid)
		ctx.preview:set_lines(transcripts[ctx.item.session.socket] or { "# loading…" })
		local _, filetype = M.style(ctx.item.session)
		if filetype then
			ctx.preview:highlight({ ft = filetype })
		end
	end

	local picker = Snacks.picker.pick({
		title = "Attach to REPL",
		items = items,
		format = "text",
		preview = show,
		confirm = function(picker, item)
			picker:close()
			if item then
				on_choice(item.session)
			end
		end,
	})

	for _, info in ipairs(sessions) do
		M.fetch(info, function(lines)
			transcripts[info.socket] = lines
			local current = not picker.closed and picker:current()
			if current and current.session == info then
				picker.preview:show(picker, { force = true })
			end
		end)
	end
end

---Pick one of `sessions` and call `on_choice(info)`.
function M.select(sessions, on_choice)
	local ok, Snacks = pcall(require, "snacks")
	if ok and Snacks.picker then
		return snacks_select(Snacks, sessions, on_choice)
	end
	vim.ui.select(sessions, { prompt = "Attach to REPL", format_item = discover.label }, function(choice)
		if choice then
			on_choice(choice)
		end
	end)
end

return M
