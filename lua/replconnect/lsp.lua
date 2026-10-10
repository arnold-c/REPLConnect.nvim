-- In-process LSP server that answers `textDocument/completion` from the
-- attached REPL's `complete` request. Editors' completion plugins (blink.cmp's
-- LSP source, nvim-cmp, built-in vim.lsp.completion) pick it up like any other
-- language server, next to fatou/JETLS.
--
-- The server reads the buffer text itself, so document sync notifications are
-- ignored. Positions use UTF-8 byte offsets (`positionEncoding = "utf-8"`),
-- which is what the REPL protocol uses.

local M = {}

M.NAME = "replconnect"

---Server name for a language, e.g. `replconnect-julia`: one server per
---language, so each filetype completes from its own REPL.
---@param language string
---@return string
function M.server_name(language)
	return M.NAME .. "-" .. language
end

---Byte offset into `table.concat(lines, "\n")` of an LSP position (UTF-8 columns).
---@param lines string[]
---@param position { line: integer, character: integer }
---@return integer
function M.position_to_offset(lines, position)
	local offset = 0
	for i = 1, math.min(position.line, #lines) do
		offset = offset + #lines[i] + 1
	end
	local line = lines[position.line + 1] or ""
	return offset + math.min(position.character, #line)
end

---LSP position of a byte offset into `table.concat(lines, "\n")`.
---@param lines string[]
---@param offset integer
---@return { line: integer, character: integer }
function M.offset_to_position(lines, offset)
	for i, line in ipairs(lines) do
		if offset <= #line then
			return { line = i - 1, character = offset }
		end
		offset = offset - #line - 1
	end
	local last = #lines
	return { line = math.max(last - 1, 0), character = #(lines[last] or "") }
end

---Convert a `complete` result into an LSP completion list.
---@param lines string[] Buffer lines the request was made for.
---@param result { items: table[], start: integer, stop: integer }
---@return table
function M.to_completion_list(lines, result)
	local range = {
		start = M.offset_to_position(lines, result.start),
		["end"] = M.offset_to_position(lines, result.stop),
	}
	local items = {}
	for _, item in ipairs(result.items or {}) do
		items[#items + 1] = {
			label = item.label,
			kind = item.kind,
			detail = item.detail,
			labelDetails = { description = "runtime" },
			textEdit = { range = range, newText = item.label },
			-- Sort in the order the REPL returned them
			sortText = ("%06d"):format(#items),
		}
	end
	-- Incomplete: the REPL's answer depends on what has been typed, so ask again.
	return { isIncomplete = true, items = items }
end

local function buffer_lines(uri)
	local bufnr = vim.uri_to_bufnr(uri)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		vim.fn.bufload(bufnr)
	end
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---Build the `cmd` function for `vim.lsp.start`.
---@param get_client fun(): replconnect.SocketClient? Resolved per request so re-attaching works.
---@param get_lines? fun(uri: string): string[]
---@param trigger_characters? string[] default: none
function M.cmd(get_client, get_lines, trigger_characters)
	get_lines = get_lines or buffer_lines
	trigger_characters = trigger_characters or {}
	return function(dispatchers)
		local closing = false
		local next_id = 0
		local server = {}

		local handlers = {
			initialize = function(_, respond)
				respond(nil, {
					capabilities = {
						positionEncoding = "utf-8",
						textDocumentSync = { openClose = true, change = 0 },
						completionProvider = { triggerCharacters = trigger_characters },
					},
					serverInfo = { name = M.NAME },
				})
			end,
			shutdown = function(_, respond)
				respond(nil, vim.NIL)
			end,
			["textDocument/completion"] = function(params, respond)
				local client = get_client()
				if not client or client.closed then
					return respond(nil, { isIncomplete = true, items = {} })
				end
				local lines = get_lines(params.textDocument.uri)
				local code = table.concat(lines, "\n")
				local cursor = M.position_to_offset(lines, params.position)
				client:request("complete", { code = code, cursor = cursor }, function(result)
					respond(nil, M.to_completion_list(lines, result))
				end, function()
					-- Completion must never produce error popups while typing.
					respond(nil, { isIncomplete = true, items = {} })
				end)
			end,
		}

		function server.request(method, params, callback)
			next_id = next_id + 1
			local handler = handlers[method]
			if handler then
				handler(params, callback)
			else
				callback({ code = -32601, message = "method not supported: " .. method })
			end
			return true, next_id
		end

		-- Tell Neovim the server has gone, so it drops the client promptly.
		local function close()
			if closing then
				return
			end
			closing = true
			if dispatchers.on_exit then
				vim.schedule(function()
					dispatchers.on_exit(0, 0)
				end)
			end
		end

		function server.notify(method)
			if method == "exit" then
				close()
			end
			return true
		end

		function server.is_closing()
			return closing
		end

		function server.terminate()
			close()
		end

		return server
	end
end

---Start (or reuse) `language`'s completion server for a buffer.
---@param bufnr integer
---@param language replconnect.Language
---@param get_client fun(): replconnect.SocketClient?
function M.attach_buffer(bufnr, language, get_client)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.lsp.start({
		name = M.server_name(language.name),
		cmd = M.cmd(get_client, nil, language.trigger_characters),
		root_dir = vim.fn.getcwd(),
	}, { bufnr = bufnr })
end

---Stop `language`'s completion server (all buffers).
---@param language string
function M.stop(language)
	for _, client in ipairs(vim.lsp.get_clients({ name = M.server_name(language) })) do
		client:stop()
	end
end

return M
