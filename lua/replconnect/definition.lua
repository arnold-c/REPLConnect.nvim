-- Function definitions for the variables pane: `v` shows a function's methods
-- in the viewer, `gd` opens where they were defined in an editor window.
--
-- Locations come from the REPL's `definition` request (capability
-- "definition"), which knows about every method, including ones typed at the
-- prompt. When the REPL cannot give a file location, `gd` falls back to the
-- `workspace/symbol` search of the language's other language servers.

local M = {}

M.CAPABILITY = "definition"

---How many lines of a file to show for a method whose source text the REPL
---did not send; the excerpt also ends at the first blank line.
M.EXCERPT_LINES = 50

---@class replconnect.DefinitionLocation
---@field signature string
---@field file? string absolute path, or a pseudo-file such as `REPL[3]`
---@field line? integer 1-based line of the definition in `file`
---@field source? string the method's source text
---@field mtime? number `file`'s modification time (seconds) when it was loaded

local function warn(message)
	vim.notify("replconnect: " .. message, vim.log.levels.WARN)
end

---@param client replconnect.SocketClient
---@return boolean
function M.supported(client)
	local capabilities = client.info and client.info.capabilities or client.capabilities or {}
	return vim.tbl_contains(capabilities, M.CAPABILITY)
end

---Ask the REPL where the value at `path` was defined.
---@param client replconnect.SocketClient
---@param path string[]
---@param on_result fun(locations: replconnect.DefinitionLocation[])
---@param on_error fun(err: { message?: string })
function M.fetch(client, path, on_result, on_error)
	client:request(M.CAPABILITY, { path = path }, function(result)
		vim.schedule(function() on_result(type(result) == "table" and result.locations or {}) end)
	end, function(err)
		vim.schedule(function() on_error(err or {}) end)
	end)
end

---@param location replconnect.DefinitionLocation
---@return boolean
local function in_file(location)
	return type(location.file) == "string" and type(location.line) == "number"
		and vim.fn.filereadable(location.file) == 1
end

---The first `count` lines of `file` from `line` on.
local function read_lines(file, line, count)
	return vim.list_slice(vim.fn.readfile(file, "", line + count - 1), line)
end

---Whether `location`'s line may no longer point at its definition: the file's
---line differs from the source's first line or, without source text, the file
---changed after it was loaded.
---@param location replconnect.DefinitionLocation
---@return boolean
function M.stale(location)
	if not in_file(location) then
		return false
	end
	if type(location.source) == "string" then
		local first = vim.trim(vim.split(location.source, "\n", { plain = true })[1])
		local actual = read_lines(location.file, location.line, 1)[1]
		return actual == nil or not actual:find(first, 1, true)
	end
	local stat = vim.uv.fs_stat(location.file)
	return type(location.mtime) == "number" and stat ~= nil and stat.mtime.sec > math.floor(location.mtime)
end

---Warn once about every location whose line may be out of date.
---@param locations replconnect.DefinitionLocation[]
local function warn_stale(locations)
	local stale = vim.tbl_filter(M.stale, locations)
	if #stale > 0 then
		local where = vim.tbl_map(function(l) return ("%s:%d"):format(l.file, l.line) end, stale)
		warn("file changed since it was loaded, line numbers may be out of date: " .. table.concat(where, ", "))
	end
end

---"file:line", or why there is none.
---@param location replconnect.DefinitionLocation
---@return string
local function where(location)
	if not location.file then
		return "no source file"
	end
	return location.line and ("%s:%d"):format(location.file, location.line) or location.file
end

---The method's source: as sent, else a file excerpt up to the first blank line.
---@param location replconnect.DefinitionLocation
---@return string[]?
local function source_lines(location)
	if type(location.source) == "string" then
		return vim.split(location.source, "\n", { plain = true })
	end
	if not in_file(location) then
		return nil
	end
	local lines = read_lines(location.file, location.line, M.EXCERPT_LINES)
	for i = 2, #lines do
		if vim.trim(lines[i]) == "" then
			return vim.list_slice(lines, 1, i - 1)
		end
	end
	return lines
end

---A function turning text into a line comment for `filetype`.
---@param filetype string
---@return fun(text: string): string
local function commenter(filetype)
	local ok, commentstring = pcall(vim.filetype.get_option, filetype, "commentstring")
	local left, right = (ok and type(commentstring) == "string" and commentstring or ""):match("^(.-)%%s(.-)$")
	left = left and vim.trim(left) ~= "" and vim.trim(left) or "#"
	return function(text) return left .. " " .. text .. (right or "") end
end

---Viewer lines for a function's methods: a title, then each method's
---signature and location as comments followed by its source.
---@param name string
---@param locations replconnect.DefinitionLocation[]
---@param filetype string
---@return string[]
function M.render(name, locations, filetype)
	local comment = commenter(filetype)
	local lines = { comment(("%s: %d method%s"):format(name, #locations, #locations == 1 and "" or "s")) }
	for _, location in ipairs(locations) do
		vim.list_extend(lines, {
			"",
			comment(location.signature or name),
			comment(where(location) .. (M.stale(location) and " (may be out of date)" or "")),
		})
		vim.list_extend(lines, source_lines(location) or { comment("source unavailable") })
	end
	return lines
end

---The language's main filetype (the language name for unregistered ones).
---@param client replconnect.SocketClient
---@return string
local function filetype_of(client)
	local language = require("replconnect.languages").get(client.language)
	return language and language.filetypes[1] or client.language
end

---Show the methods of the function at `path` in the client's viewer.
---@param client replconnect.SocketClient
---@param path string[]
---@param name string shown in the title
function M.view(client, path, name)
	if not M.supported(client) then
		return warn(("this %s REPL cannot show function definitions (no %q capability)")
			:format(client.language, M.CAPABILITY))
	end
	M.fetch(client, path, function(locations)
		if #locations == 0 then
			return warn(("no definition found for `%s`"):format(name))
		end
		warn_stale(locations)
		local filetype = filetype_of(client)
		require("replconnect.view").show_text(client, M.render(name, locations, filetype),
			vim.treesitter.language.get_lang(filetype) or filetype)
	end, function(err)
		vim.notify("replconnect: definition failed: " .. tostring(err.message), vim.log.levels.ERROR)
	end)
end

----------------------------------------------------------------------------
-- Go to definition
----------------------------------------------------------------------------

---An editor window to open files in: the previous window if it shows a file
---buffer, else the first such window of the tab.
---@return integer?
local function editor_window()
	local candidates = vim.tbl_filter(function(win)
		return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
	end, require("replconnect.layout").tab_windows())
	local previous = vim.fn.win_getid(vim.fn.winnr("#"))
	return vim.tbl_contains(candidates, previous) and previous or candidates[1]
end

---Focus an editor window (opening one left of everything when there is none),
---recording the current position in its jumplist.
function M.focus_editor()
	local win = editor_window()
	if win then
		vim.api.nvim_set_current_win(win)
	else
		vim.cmd("topleft vnew")
	end
	vim.cmd("normal! m'")
end

---Open `file` at `line` in an editor window. `:hide edit` keeps a modified
---buffer shown there loaded in the background instead of failing with E37.
---@param file string
---@param line integer 1-based
function M.jump(file, line)
	M.focus_editor()
	vim.cmd("hide edit " .. vim.fn.fnameescape(file))
	vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(line, vim.api.nvim_buf_line_count(0))), 0 })
	vim.cmd("normal! zz")
end

---Call `on_choice` with the only item, or the one the user picks.
---@generic T
---@param items T[]
---@param format fun(item: T): string
---@param on_choice fun(item: T)
local function choose(items, format, on_choice)
	if #items == 1 then
		return on_choice(items[1])
	end
	vim.ui.select(items, { prompt = "Definition", format_item = format }, function(item)
		if item then on_choice(item) end
	end)
end

---Whether a workspace symbol's name refers to `name` (servers may qualify it
---with a module or append a signature).
---@param symbol_name string
---@param name string
---@return boolean
function M.symbol_matches(symbol_name, name)
	local base = vim.trim(symbol_name:match("^[^(]*"))
	return base == name or vim.endswith(base, "." .. name) or vim.endswith(base, "::" .. name)
end

---Whether an attached LSP client can search workspace symbols for us.
local function searchable(lsp_client)
	return not vim.startswith(lsp_client.name, require("replconnect.lsp").NAME)
		and lsp_client.server_capabilities ~= nil
		and lsp_client.server_capabilities.workspaceSymbolProvider ~= nil
		and lsp_client.server_capabilities.workspaceSymbolProvider ~= false
end

---A loaded buffer of one of `filetypes` with a language server that can search
---workspace symbols, preferring the current buffer.
---@param filetypes string[]
---@return integer?
local function symbol_buffer(filetypes)
	local buffers = vim.api.nvim_list_bufs()
	table.insert(buffers, 1, vim.api.nvim_get_current_buf())
	for _, bufnr in ipairs(buffers) do
		if vim.api.nvim_buf_is_loaded(bufnr) and vim.tbl_contains(filetypes, vim.bo[bufnr].filetype)
			and vim.iter(vim.lsp.get_clients({ bufnr = bufnr })):any(searchable) then
			return bufnr
		end
	end
end

---@class replconnect.SymbolTarget
---@field name string
---@field location { uri: string, range?: table }
---@field encoding string

---Search the language servers attached to `filetypes` buffers for `name`.
---@param filetypes string[]
---@param name string
---@param on_done fun(targets: replconnect.SymbolTarget[])
function M.search_symbols(filetypes, name, on_done)
	local bufnr = symbol_buffer(filetypes)
	if not bufnr then
		return on_done({})
	end
	vim.lsp.buf_request_all(bufnr, "workspace/symbol", { query = name }, function(responses)
		local targets = {}
		for client_id, response in pairs(responses) do
			local lsp_client = vim.lsp.get_client_by_id(client_id)
			for _, symbol in ipairs(type(response.result) == "table" and response.result or {}) do
				if symbol.location and M.symbol_matches(symbol.name, name) then
					targets[#targets + 1] = {
						name = symbol.name,
						location = symbol.location,
						encoding = lsp_client and lsp_client.offset_encoding or "utf-16",
					}
				end
			end
		end
		vim.schedule(function() on_done(targets) end)
	end)
end

---@param target replconnect.SymbolTarget
---@return string
local function target_label(target)
	local line = target.location.range and target.location.range.start.line + 1 or 1
	return ("%s — %s:%d"):format(target.name, vim.fn.fnamemodify(vim.uri_to_fname(target.location.uri), ":~:."), line)
end

---Open a workspace symbol's location in an editor window.
---@param target replconnect.SymbolTarget
local function open_target(target)
	local origin = { line = 0, character = 0 }
	local location = vim.tbl_extend("keep", target.location, { range = { start = origin, ["end"] = origin } })
	M.focus_editor()
	vim.lsp.util.show_document(location, target.encoding, { focus = true })
	vim.cmd("normal! zz")
end

---Search the language servers for `name` after warning why.
---@param client replconnect.SocketClient
---@param name string
---@param reason string
---@param repl_source boolean whether `v` can still show the REPL's source
local function lsp_fallback(client, name, reason, repl_source)
	warn(("%s; searching language servers for `%s`"):format(reason, name))
	local language = require("replconnect.languages").get(client.language)
	M.search_symbols(language and language.filetypes or { client.language }, name, function(targets)
		if #targets == 0 then
			return warn(("no language server found `%s`%s"):format(name,
				repl_source and "; press v to view its source" or ""))
		end
		choose(targets, target_label, open_target)
	end)
end

---The line of `source` to look for in buffers: the first that mentions `name`
---(sent code may start with comments or cell markers), else its first non-blank line.
---@param source string
---@param name string
---@return string?
function M.anchor(source, name)
	local first
	for _, line in ipairs(vim.split(source, "\n", { plain = true })) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			if trimmed:find(name, 1, true) then
				return trimmed
			end
			first = first or trimmed
		end
	end
	return first
end

---Locations in loaded `filetypes` buffers whose line equals the anchor of a
---method's source: where code sent from a file (`REPL[n]`) came from.
---@param locations replconnect.DefinitionLocation[]
---@param filetypes string[]
---@param name string
---@return replconnect.DefinitionLocation[]
function M.find_in_buffers(locations, filetypes, name)
	local found, seen = {}, {}
	for _, location in ipairs(locations) do
		local anchor = type(location.source) == "string" and M.anchor(location.source, name)
		for _, bufnr in ipairs(anchor and vim.api.nvim_list_bufs() or {}) do
			local file = vim.api.nvim_buf_get_name(bufnr)
			if vim.api.nvim_buf_is_loaded(bufnr) and file ~= ""
				and vim.tbl_contains(filetypes, vim.bo[bufnr].filetype) then
				for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
					local key = file .. ":" .. i
					if vim.trim(line) == anchor and not seen[key] then
						seen[key] = true
						found[#found + 1] = { signature = location.signature, file = file, line = i }
					end
				end
			end
		end
	end
	return found
end

---Open where the function at `path` was defined in an editor window. Code sent
---from a file is found in loaded buffers by its source; otherwise falls back
---to the language servers.
---@param client replconnect.SocketClient
---@param path string[]
---@param name string the function's name, for the language server search
function M.go(client, path, name)
	if not M.supported(client) then
		return lsp_fallback(client, name, ("this %s REPL cannot locate definitions"):format(client.language), false)
	end
	M.fetch(client, path, function(locations)
		local files = vim.tbl_filter(in_file, locations)
		warn_stale(files)
		local language = require("replconnect.languages").get(client.language)
		local sent = vim.tbl_filter(function(l) return not in_file(l) end, locations)
		vim.list_extend(files, M.find_in_buffers(sent, language and language.filetypes or { client.language }, name))
		if #files == 0 then
			local reason = #locations > 0 and ("`%s` was not defined in a readable file"):format(name)
				or ("the REPL found no definition of `%s`"):format(name)
			return lsp_fallback(client, name, reason, #locations > 0)
		end
		choose(files, function(l) return ("%s — %s"):format(l.signature or name, where(l)) end,
			function(l) M.jump(l.file, l.line) end)
	end, function(err)
		lsp_fallback(client, name, "definition request failed: " .. tostring(err.message), false)
	end)
end

return M
