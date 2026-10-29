-- Adapted from wurli/jet.ark, lua/jet/ark/ark_kernel/vars.lua:
-- https://github.com/wurli/jet.ark/blob/main/lua/jet/ark/ark_kernel/vars.lua
-- MIT License, Copyright (c) 2025 Jacob Scott. See LICENSES/jet.ark-MIT.txt.
--
-- A variables pane over a replconnect client. Changes from the original:
--   * no dependency on jet.ark: pull-based `list`/`changes` requests replace
--     the pushed refresh/update events; local highlight groups
--   * assigned variables replace existing ones instead of duplicating them
--   * every keymap is buffer-local; display strings are single-line
--   * client-side exclusions, window-relative columns and viewer integration
-- See docs/attribution.md for upstream references.

local buf = require("replconnect.buf")
local sync = require("replconnect.sync")

---@class replconnect.Var
---@field access_key string
---@field display_name string
---@field display_value string
---@field display_type string
---@field kind string
---@field has_children boolean
---@field expanded? boolean
---@field children? replconnect.Var[]

---@class replconnect.FlatVar : replconnect.Var
---@field path string[]
---@field indent integer
---@field display_name_w integer
---@field display_value_w integer
---@field display_type_w integer

---@class replconnect.Vars : replconnect.Buf
---@field vars replconnect.Var[]
---@field vars_flat (replconnect.FlatVar | string)[]
---@field version integer
---@field length integer
---@field client replconnect.SocketClient
local Vars = setmetatable({}, { __index = buf })
Vars.__index = Vars ---@private

---Create the pane for an attached client and install local maps, resize redraws
---and sync triggers (entering the pane, terminal focus).
---@param client replconnect.SocketClient
---@return replconnect.Vars
Vars.init = function(client)
	require("replconnect.highlights").setup()

	local out = buf.init(Vars, { name = ("%s (pid %s) - Variables"):format(client.language, client.pid) })
	out.client = client

	out.vars = {}
	out.vars_flat = {}
	out.length = 0
	out.version = 0

	vim.bo[out.buf].filetype = "inspectvars"
	vim.bo[out.buf].modifiable = false
	vim.bo[out.buf].buftype = "nofile"

	out:set_keymaps()

	local group = vim.api.nvim_create_augroup("replconnect.vars." .. tostring(client.pid), { clear = true })
	vim.api.nvim_create_autocmd("WinResized", {
		group = group,
		callback = function()
			local win = out:winid()
			if win and vim.tbl_contains(vim.v.event.windows or {}, win) then
				out:redraw()
			end
		end,
	})
	-- Triggers arrive in bursts (BufEnter + WinEnter + FocusGained); sync once.
	local request_sync, close_debounce = sync.debounce(function() out:sync() end)
	out.request_sync = request_sync
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
		group = group,
		buffer = out.buf,
		callback = function() request_sync() end,
	})
	vim.api.nvim_create_autocmd("FocusGained", {
		group = group,
		callback = function()
			if out:winid() then
				request_sync()
			end
		end,
	})

	local stop_poll = function() end
	local interval = require("replconnect.config").options.poll_interval_ms or 0
	if interval > 0 then
		stop_poll = sync.poll(interval, function() return out:winid() ~= nil end, request_sync)
	end
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = out.buf,
		callback = function()
			close_debounce()
			stop_poll()
		end,
	})

	return out
end

----------------------------------------------------------------------------
-- Sync
----------------------------------------------------------------------------

---Fetch the full list again and redraw.
function Vars:refresh()
	self:list(function() self:redraw() end)
end

-- A REPL that is evaluating cannot answer (it is single-threaded and the server
-- runs on it), so a status request that times out means "busy", not "broken".
local STATUS_TIMEOUT_MS = 1000

---How long a visible pane waits before checking again while the REPL is busy or
---not answering, so the marker clears on its own once the REPL is idle.
Vars.RETRY_MS = 1000

---While the REPL is busy or silent, keep checking (only if the pane is visible).
function Vars:schedule_retry()
	if self.retry_pending or self.client.closed or not (self.stale or self.busy) then
		return
	end
	self.retry_pending = true
	vim.defer_fn(function()
		self.retry_pending = false
		if self:valid() and self:winid() then
			self:sync()
		end
	end, Vars.RETRY_MS)
end

---Show connection state in the window bar (not the buffer, so line numbers keep
---matching `vars_flat`): which session this is, and whether values may be stale.
function Vars:update_header()
	local win = self:winid()
	if not win then
		return
	end
	local c = self.client
	local version = c.info and c.info.language_version or ""
	local text = (" %s %s \xc2\xb7 pid %s"):format(c.language, version, tostring(c.pid))
	if c.closed then
		text = text .. " \xc2\xb7 REPL exited; :REPLAttach to reconnect"
	elseif self.stale then
		text = text .. " \xc2\xb7 REPL busy; showing last known values"
	elseif self.busy then
		text = text .. " \xc2\xb7 evaluating"
	end
	vim.wo[win].winbar = (text:gsub("%%", "%%%%"))
end

---Ask the REPL whether anything changed, and fetch only what did: `status` is
---O(1); `changes` runs only when the version moved. Skipped while a previous
---sync is still waiting for a busy REPL.
function Vars:sync()
	if self.client.closed then
		return self:update_header()
	end
	if self.syncing then
		return
	end
	self.syncing = true
	local done = function()
		self.syncing = false
		self:update_header()
		self:schedule_retry()
	end
	self.client:request("status", nil, function(status)
		self.stale = false
		self.busy = status.busy
		if status.version == self.version then
			return done()
		end
		-- A REPL that answers while evaluating is yielding inside user code; scanning
		-- the workspace there would slow that computation down. Wait until it is idle
		-- (`schedule_retry` keeps checking), unless the user opted in.
		if status.busy and not require("replconnect.config").options.update_while_busy then
			return done()
		end
		self.client:request("changes", { since = self.version }, function(res)
			if res.refresh then
				self:refresh()
			elseif res.assigned or res.removed then
				self:on_update(res)
			else
				self.version = res.version
			end
			done()
		end, function()
			self.stale = true
			done()
		end)
	end, function()
		self.stale = not self.client.closed
		done()
	end, STATUS_TIMEOUT_MS)
end

---Apply removals/assignments, reinspect expanded roots and redraw; length is unchanged.
---@param params table Changes payload: version, removed and assigned.
function Vars:on_update(params)
	self.version = params.version
	for _, key in ipairs(params.removed or {}) do
		self:rm(key)
	end
	for _, var in ipairs(params.assigned or {}) do
		local reinspect = self:upsert(var)
		if reinspect then
			self:inspect({ var.access_key })
		end
	end
	self.length = #self.vars
	self:redraw()
end

---Replace the top-level variable with the same access key, or append it.
---@param var replconnect.Var
---@return boolean # Whether the variable was expanded and needs re-inspecting
function Vars:upsert(var)
	for i, existing in ipairs(self.vars) do
		if existing.access_key == var.access_key then
			var.expanded = existing.expanded and var.has_children
			self.vars[i] = var
			return var.expanded == true
		end
	end
	table.insert(self.vars, var)
	return false
end

---Remove a cached top-level variable by access key; do not request deletion or redraw.
---@param key string
function Vars:rm(key)
	for i, var in ipairs(self.vars) do
		if var.access_key == key then
			table.remove(self.vars, i)
			return
		end
	end
end

---Fetch a fresh top-level list; callback runs after cache replacement, without automatic redraw.
---@param cb? fun()
function Vars:list(cb)
	self.client:request("list", nil, function(res)
		self.vars = res.variables
		self.length = res.length
		self.version = res.version
		if cb then
			cb()
		end
	end)
end

---Request clearing the backend workspace (hidden objects included unless false).
---REPLConnect currently ignores this flag and deletes visible bindings only.
---@param hidden? boolean
function Vars:clear(hidden)
	self.client:request("clear", { include_hidden_objects = hidden ~= false }, function() self:refresh() end)
end

---Delete top-level names remotely, remove successfully deleted cache entries and redraw.
---@param names string | string[]
function Vars:delete(names)
	names = type(names) == "string" and { names } or names
	self.client:request("delete", { names = names }, function(deleted)
		for _, key in ipairs(deleted) do
			self:rm(key)
		end
		self:redraw()
	end)
end

---Fetch children asynchronously, cache them and expand/redraw if the path still exists.
---@param path string[]
---@param cb? fun(var: replconnect.Var) Called after children are cached
function Vars:inspect(path, cb)
	assert(#path > 0)
	self.client:request("inspect", { path = path }, function(res)
		local var = self:get_var(path)
		if var then
			var.children = res.children
			var.expanded = true
			self:redraw()
			if cb then
				cb(var)
			end
		end
	end)
end

---Request unlimited clipboard text/HTML and pass the returned content to cb.
---@param path string[]
---@param format? "text/plain" | "text/html"
---@param cb fun(text: string)
function Vars:clipboard_format(path, format, cb)
	assert(#path > 0)
	self.client:request("clipboard_format", { path = path, format = format or "text/plain" }, function(res)
		cb(res.content)
	end)
end

----------------------------------------------------------------------------
-- Tree
----------------------------------------------------------------------------

---Resolve an access path in the cached tree only; missing/unfetched children return nil.
---@param path string[]
---@return replconnect.Var?
function Vars:get_var(path)
	local var ---@type replconnect.Var?
	local children = self.vars ---@type replconnect.Var[]?
	for _, key in ipairs(path) do
		var = nil
		for _, candidate in ipairs(children or {}) do
			if candidate.access_key == key then
				var = candidate
				break
			end
		end
		if not var then
			return nil
		end
		children = var.children
	end
	return var
end

---Collapse a cached node without discarding its fetched children, then redraw.
---@param path string[]
function Vars:collapse(path)
	local var = self:get_var(path)
	if var and var.expanded then
		var.expanded = false
		self:redraw()
	end
end

---Expand a cached node, reusing children when present or requesting them when inspectable.
---@param path string[]
function Vars:expand(path)
	local var = self:get_var(path)
	if not var or var.expanded then
		return
	end
	var.expanded = true
	if var.children then
		self:redraw()
	elseif var.has_children then
		self:inspect(path)
	end
end

local MAX_EXPAND_DEPTH = 8 -- guards against cyclic or very deep structures

---Expand a node and, recursively, all of its descendants (fetching as needed).
---@param path string[]
---@param depth? integer
function Vars:expand_all(path, depth)
	depth = depth or 0
	local var = self:get_var(path)
	if not var or not var.has_children or depth >= MAX_EXPAND_DEPTH then
		return
	end
	local descend = function(node)
		for _, child in ipairs(node.children or {}) do
			self:expand_all(vim.list_extend(vim.deepcopy(path), { child.access_key }), depth + 1)
		end
	end
	var.expanded = true
	if var.children then
		self:redraw()
		descend(var)
	else
		self:inspect(path, descend)
	end
end

---Collapse a node and all cached descendants (inverse of `expand_all`), then redraw.
---@param path string[]
function Vars:collapse_all(path)
	local var = self:get_var(path)
	if not var then
		return
	end
	local collapse
	collapse = function(node)
		node.expanded = false
		for _, child in ipairs(node.children or {}) do
			collapse(child)
		end
	end
	collapse(var)
	self:redraw()
end

----------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------

---Open the secondary pane with wrapping disabled and refresh its list asynchronously.
---@return integer win
---@param open_window? replconnect.WindowOpener see `Buf.open`
function Vars:open(open_window)
	local win = buf.open(self, open_window)
	-- Columns are sized to the window; never wrap
	vim.wo[win].wrap = false
	self:update_header()
	self:refresh()
	return win
end

---The variable on the cursor line, if the line holds one.
---@return replconnect.FlatVar?
function Vars:current_var()
	local var = self.vars_flat[vim.fn.line(".")]
	if type(var) == "table" then
		return var
	end
end

---Install buffer-local viewing, expansion, navigation, copying and deletion bindings.
function Vars:set_keymaps()
	---Install one silent mapping (or mode list) on this pane only.
	---@param modes string | string[]
	---@param lhs string
	---@param fn string | function
	local map = function(modes, lhs, fn) vim.keymap.set(modes, lhs, fn, { buffer = self.buf, silent = true }) end

	map("n", "q", "<cmd>q<cr>")
	map("n", "r", function() self:refresh() end)
	map("n", "v", function()
		local var = self:current_var()
		if not var then
			return
		end
		if var.kind == "function" then
			require("replconnect.definition").view(self.client, var.path, var.display_name)
		else
			require("replconnect.view").open(self.client, var.path)
		end
	end)

	map("n", "gd", function()
		local var = self:current_var()
		if var and var.kind == "function" then
			require("replconnect.definition").go(self.client, var.path, var.display_name)
		elseif var then
			vim.notify("replconnect: gd goes to the definitions of functions", vim.log.levels.INFO)
		end
	end)

	map("n", "<enter>", function()
		local var = self:current_var()
		if not var then
			return
		end
		if var.expanded then
			self:collapse(var.path)
		else
			self:expand(var.path)
		end
	end)

	map("n", "<leader>y", function()
		local var = self:current_var()
		if var then
			local reg = vim.v.register
			self:clipboard_format(var.path, "text/plain", function(text) vim.fn.setreg(reg, text) end)
		end
	end)

	---Move to the next/previous top-level variable, skipping headings and children.
	---@param direction integer 1 or -1.
	local next_var = function(direction)
		for i = vim.fn.line(".") + direction, direction > 0 and #self.vars_flat or 1, direction do
			local var = self.vars_flat[i]
			if type(var) == "table" and var.indent == 0 then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				return
			end
		end
	end
	map({ "n", "x" }, "]]", function() next_var(1) end)
	map({ "n", "x" }, "[[", function() next_var(-1) end)

	map("n", ">", function()
		local var = self:current_var()
		if var then
			self:expand(var.path)
		end
	end)

	map("n", "<leader>>", function()
		local var = self:current_var()
		if var then
			self:expand_all(var.path)
		end
	end)

	-- Collapse every level: the top-level ancestor and all its descendants
	map("n", "<leader><", function()
		local var = self:current_var()
		if not var then
			return
		end
		local path = { var.path[1] }
		self:collapse_all(path)
		for line, line_var in ipairs(self.vars_flat) do
			if type(line_var) == "table" and vim.deep_equal(line_var.path, path) then
				vim.api.nvim_win_set_cursor(0, { line, 0 })
				return
			end
		end
	end)

	map("n", "g?", function() self:show_help() end)

	map("n", "<", function()
		local var = self:current_var()
		if not var then
			return
		end
		if var.expanded then
			self:collapse(var.path)
		elseif #var.path > 1 then
			local parent_path = vim.list_slice(var.path, 1, #var.path - 1)
			self:collapse(parent_path)
			for line, line_var in ipairs(self.vars_flat) do
				if type(line_var) == "table" and vim.deep_equal(line_var.path, parent_path) then
					vim.api.nvim_win_set_cursor(0, { line, 0 })
					return
				end
			end
		end
	end)

	map("n", "<leader>d", function()
		local var = self:current_var()
		if var and #var.path == 1 then
			self:delete(var.path)
			vim.api.nvim_win_set_cursor(0, { math.max(1, vim.fn.line(".") - 1), 0 })
		end
	end)

	map("n", "X", function() self:clear(true) end)
end

---Show the available shortcuts in a floating window.
function Vars:show_help()
	require("replconnect.help").open("Variable viewer shortcuts", {
		{ "<enter>", "toggle expand/collapse" },
		{ ">", "expand" },
		{ "<leader>>", "expand all levels recursively" },
		{ "<", "collapse (or go to parent)" },
		{ "<leader><", "collapse all levels up to the top-level variable" },
		{ "]] / [[", "next / previous top-level variable" },
		{ "v", "open in viewer (functions: their source)" },
		{ "gd", "go to a function's definition" },
		{ "r", "refresh" },
		{ "<leader>y", "yank value" },
		{ "<leader>d", "delete variable" },
		{ "X", "clear all variables" },
		{ "g?", "show this help" },
		{ "q", "close" },
	})
end

---Replace buffer lines and session-namespace highlights from the current cached tree.
function Vars:redraw()
	local lines, extmarks = self:render()
	vim.bo[self.buf].modifiable = true
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
	vim.bo[self.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
	for line, marks in ipairs(extmarks) do
		for _, mark in ipairs(marks) do
			vim.api.nvim_buf_set_extmark(self.buf, self.ns, line - 1, mark[1], mark[2])
		end
	end
end

-- Byte escapes, so the Nerd Font glyphs cannot be lost when editing the file
local icons = {
	caret_right = "\xef\x83\x9a", -- U+F0DA nf-fa-caret_right
	caret_down = "\xef\x83\x97", -- U+F0D7 nf-fa-caret_down
	ellipsis = "\xe2\x80\xa6", -- U+2026 …
}

---The caret for a variable, padded so every row's caret is one cell wide.
---@param v replconnect.FlatVar
---@return string
local caret_for = function(v)
	local caret = not v.has_children and "" or v.expanded and icons.caret_down or icons.caret_right
	return caret .. string.rep(" ", math.max(1 - vim.fn.strwidth(caret), 0))
end

---@alias replconnect.extmark_args [ integer, vim.api.keyset.set_extmark ]

---Mirrors Positron's grouping:
---https://github.com/posit-dev/positron/blob/main/src/vs/workbench/services/positronVariables/common/positronVariablesInstance.ts#L723
---@param kind string
---@return "DATA" | "FUNCTIONS" | "CLASSES" | "VALUES"
local category = function(kind)
	return kind == "table" and "DATA" or kind == "function" and "FUNCTIONS" or kind == "class" and "CLASSES" or "VALUES"
end

local CATEGORY_ORDER = { "DATA", "FUNCTIONS", "CLASSES", "VALUES" }

---Collapse CR/LF runs to spaces for single-line pane text.
---@param s string
---@return string
local single_line = function(s) return (tostring(s):gsub("[\r\n]+", " ")) end

---Copy a node without children, attach its full access path and measure sanitised text.
---@param var replconnect.Var
---@param path string[] Parent path.
---@param level integer Zero-based depth.
---@return replconnect.FlatVar
local flatten = function(var, path, level)
	local flat = {}
	for k, v in pairs(var) do
		if k ~= "children" then
			flat[k] = v
		end
	end
	flat.display_name = single_line(var.display_name)
	flat.display_value = single_line(var.display_value)
	flat.display_type = single_line(var.display_type)
	flat.path = vim.list_extend(vim.deepcopy(path), { var.access_key })
	flat.indent = level * 2
	flat.display_name_w = vim.fn.strwidth(flat.display_name)
	flat.display_value_w = vim.fn.strwidth(flat.display_value)
	flat.display_type_w = vim.fn.strwidth(flat.display_type)
	return flat
end

---Whether a top-level variable is hidden by the `exclude` option.
---@param var replconnect.Var
---@return boolean
local is_excluded = function(var)
	local exclude = require("replconnect.config").options.exclude
	if type(exclude) == "function" then
		return exclude(var) == true
	end
	return vim.tbl_contains(exclude or {}, var.access_key)
end

---Left-align `s` in `width` cells: pad, or truncate by characters with an ellipsis.
---Wide glyphs can exceed width after truncation; this is not an exact cell fit.
---@param s string
---@param width integer
---@return string padded
---@return string text # `s`, truncated if needed (for highlight extents)
local fit = function(s, width)
	local w = vim.fn.strwidth(s)
	if w > width then
		s = width <= 1 and icons.ellipsis or vim.fn.strcharpart(s, 0, width - 1) .. icons.ellipsis
		w = vim.fn.strwidth(s)
	end
	return s .. string.rep(" ", math.max(width - w, 0)), s
end

-- Column widths as fractions of the window; the value gets the rest.
local NAME_MAX_FRAC = 0.35
local TYPE_MAX_FRAC = 0.3
local TYPE_MIN = 15
local MIN_COL = 8
local SEP = "  "

---Column widths for a window. Name and type are capped at a fraction of the
---window; the type keeps at least `TYPE_MIN` cells (or all it needs, if less)
---and is hidden first, before the value would drop below `MIN_COL`.
---@param win_width integer
---@param name_max integer Widest name, including indent.
---@param type_max integer Widest type.
---@return integer name_w
---@return integer val_w
---@return integer type_w # 0 when the type column is hidden
local layout = function(win_width, name_max, type_max)
	local name_w = math.min(name_max, math.max(MIN_COL, math.floor(win_width * NAME_MAX_FRAC)))
	local type_w = math.min(type_max, math.max(TYPE_MIN, math.floor(win_width * TYPE_MAX_FRAC)))
	-- 2 cells for caret + space before the name
	local before_val = 2 + name_w + #SEP
	local val_w = win_width - before_val - #SEP - type_w
	if type_w == 0 or val_w < MIN_COL then
		return name_w, math.max(win_width - before_val, MIN_COL), 0
	end
	return name_w, val_w, type_w
end
Vars._layout = layout -- exposed for tests

---Flatten the (partially expanded) variable tree into display order.
---@return (replconnect.FlatVar | string)[]
function Vars:flatten()
	local categories = {}
	for _, c in ipairs(CATEGORY_ORDER) do
		categories[c] = {}
	end
	for _, var in ipairs(self.vars) do
		if not is_excluded(var) then
			table.insert(categories[category(var.kind)], var)
		end
	end
	local by_name = function(a, b)
		local x, y = a.display_name:lower(), b.display_name:lower()
		if x ~= y then return x < y end
		return a.display_name < b.display_name
	end
	for _, vars in pairs(categories) do
		table.sort(vars, by_name)
	end

	local out = {}

	---Append nodes depth-first; descend only into expanded nodes with cached children.
	---@param vars replconnect.Var[]
	---@param path string[]
	---@param level integer
	local function unpack_vars(vars, path, level)
		for _, var in ipairs(vars) do
			local flat = flatten(var, path, level)
			table.insert(out, flat)
			if var.expanded and var.children then
				unpack_vars(var.children, flat.path, level + 1)
			end
		end
	end

	for _, c in ipairs(CATEGORY_ORDER) do
		if #categories[c] > 0 then
			table.insert(out, c)
			unpack_vars(categories[c], {}, 0)
			table.insert(out, "")
		end
	end

	return out
end

---Rebuild vars_flat and produce pane lines plus per-line byte-column highlight extmarks.
---Columns follow `layout`; minimum widths can still overflow very narrow windows.
---@return string[]
---@return replconnect.extmark_args[][]
function Vars:render()
	self.vars_flat = self:flatten()

	if #self.vars_flat == 0 then
		local text = "No variables to display"
		return { text }, { { { 0, { hl_group = "Comment", end_col = #text } } } }
	end

	---Maximum measured width over variable rows (ignore headings and separators).
	---@param f fun(v: replconnect.FlatVar): integer
	local var_max = function(f)
		local widths = vim.tbl_map(function(var) return type(var) == "table" and f(var) or 0 end, self.vars_flat)
		return math.max(0, unpack(widths))
	end

	local win = self:winid()
	local win_width = win and vim.api.nvim_win_get_width(win) or math.floor(vim.o.columns / 2)

	local name_w, val_w, type_w = layout(
		win_width,
		var_max(function(v) return v.display_name_w + v.indent end),
		var_max(function(v) return v.display_type_w end)
	)

	local lines = {} ---@type string[]
	local marks = {} ---@type replconnect.extmark_args[][]

	for _, v in ipairs(self.vars_flat) do
		if type(v) == "string" then
			table.insert(lines, v)
			table.insert(marks, { { 0, { hl_group = "InspectVarsCategory", end_col = #v } } })
		else
			local indent = string.rep(" ", v.indent)
			local caret = caret_for(v)
			local prefix = indent .. caret .. " "

			local name_col, name = fit(v.display_name, math.max(name_w - v.indent, 1))
			local val_col, val = fit(v.display_value, val_w)

			local name_start = #prefix
			local val_start = name_start + #name_col + #SEP
			local row_marks = {
				{ v.indent, { hl_group = "InspectVarsIndent", end_col = v.indent + #caret } },
				{ name_start, { hl_group = "InspectVarsName", end_col = name_start + #name } },
				{ val_start, { hl_group = "InspectVarsValue", end_col = val_start + #val } },
			}

			-- The last column is not padded, so lines carry no trailing blanks
			local line = prefix .. name_col .. SEP
			if type_w > 0 then
				local _, vtype = fit(v.display_type, type_w)
				local type_start = val_start + #val_col + #SEP
				line = line .. val_col .. SEP .. vtype
				table.insert(row_marks, { type_start, { hl_group = "InspectVarsType", end_col = #line } })
			else
				line = line .. val
			end

			table.insert(lines, line)
			table.insert(marks, row_marks)
		end
	end

	return lines, marks
end

return Vars
