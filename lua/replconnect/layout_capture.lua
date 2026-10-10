-- Capture the sizes of the current pane arrangement as a layout string, so
-- manual resizing can be written back into the user's config.
--
-- The configured layout for the current mode supplies the structure (order,
-- grouping, alternatives); the windows on screen supply the sizes. A region
-- is measured as a percentage of the region that contains it, except where
-- the configured layout gives that region a cell size (`@ 60`): then cells
-- are kept. In each group one visible region stays unsized and takes the
-- remainder (the one containing the editor, else the last visible one), so
-- rounding never makes the captured layout over- or under-fill its space.
-- Panes that are not open cannot be measured and keep their configured size.

local layout = require("replconnect.layout")

local M = {}

---Windows showing each leaf of `node`: its pane window, or every editor window.
local function windows(node, ctx)
	local out = {}
	for _, leaf in ipairs(layout.leaves(node)) do
		if leaf.name == "editor" then
			vim.list_extend(out, ctx.editors)
		elseif ctx.wins[leaf.name] then
			out[#out + 1] = ctx.wins[leaf.name]
		end
	end
	return out
end

---Cells `node` spans along `dir` ("row": width, "col": height); nil when hidden.
local function extent(node, dir, ctx)
	local first, last
	for _, win in ipairs(windows(node, ctx)) do
		local pos = vim.api.nvim_win_get_position(win)[dir == "row" and 2 or 1]
		local len = dir == "row" and vim.api.nvim_win_get_width(win) or vim.api.nvim_win_get_height(win)
		first = math.min(first or pos, pos)
		last = math.max(last or pos + len, pos + len)
	end
	return first and last - first or nil
end

local function contains_editor(node)
	for _, leaf in ipairs(layout.leaves(node)) do
		if leaf.name == "editor" then return true end
	end
	return false
end

---Copy of `node` with sizes measured from the screen.
local function measure(node, ctx)
	local copy = vim.tbl_extend("force", {}, node)
	if node.name or node.alternatives then
		-- Alternatives share one region; their members are never sized.
		return copy
	end
	copy.children = {}
	local visible = {}
	for i, child in ipairs(node.children) do
		copy.children[i] = measure(child, ctx)
		if extent(child, node.dir, ctx) then visible[#visible + 1] = i end
	end
	-- One visible child fills the region; nothing to measure between siblings.
	if #visible < 2 then return copy end
	-- The remainder: the region with the editor, else the last visible one not
	-- sized in cells (so configured cell sizes are kept), else the last.
	local remainder = visible[#visible]
	for _, i in ipairs(visible) do
		if not node.children[i].size_cells then remainder = i end
	end
	for _, i in ipairs(visible) do
		if contains_editor(node.children[i]) then remainder = i end
	end
	local total = extent(node, node.dir, ctx)
	for _, i in ipairs(visible) do
		local child = copy.children[i]
		if i == remainder then
			child.size, child.size_cells = nil, nil
		else
			local cells = extent(node.children[i], node.dir, ctx)
			if child.size_cells then
				child.size = math.max(1, cells)
			else
				child.size = math.min(100, math.max(1, math.floor(cells / total * 100 + 0.5))) / 100
			end
		end
	end
	return copy
end

-- Binding strength: | loosest, then /, then \, then a pane name.
local PRECEDENCE = { row = 1, col = 2, alternatives = 3, name = 4 }
local SYMBOL = { row = " | ", col = " / ", alternatives = " \\ " }

local function kind(node)
	return node.name and "name" or node.alternatives and "alternatives" or node.dir
end

---Render a layout tree as a string; parentheses only where needed.
---@param node replconnect.LayoutNode
---@param min? integer lowest precedence allowed without parentheses
---@return string
function M.serialize(node, min)
	min = type(min) == "number" and min or 0
	local k = kind(node)
	local text
	if node.name then
		text = node.name
	else
		-- Children must bind tighter than this operator, so equal-precedence
		-- nesting (a row inside a row) keeps its own group.
		local parts = {}
		for _, child in ipairs(node.children) do
			parts[#parts + 1] = M.serialize(child, PRECEDENCE[k] + 1)
		end
		text = table.concat(parts, SYMBOL[k])
	end
	if node.size then
		if not node.name then text = "(" .. text .. ")" end
		local size = node.size_cells and ("%d"):format(node.size)
			or ("%g%%"):format(math.floor(node.size * 1000 + 0.5) / 10)
		return text .. " @ " .. size
	end
	if not node.name and PRECEDENCE[k] < min then
		return "(" .. text .. ")"
	end
	return text
end

---@class replconnect.LayoutCapture
---@field mode "horizontal" | "vertical" | "external"
---@field layout string the measured layout string
---@field hidden string[] panes in the layout that are not open (sizes kept from config)
---@field from_function boolean the configured layout was a function

---Measure the panes in the current tab against the configured layout.
---@param bufs table<string, integer> buffer of each managed pane
---@return replconnect.LayoutCapture
function M.capture(bufs)
	local layouts = require("replconnect.config").options.layout
	local wins = layout.visible(bufs)
	local mode = layout.mode(bufs.repl, wins.repl)
	local source = layouts[mode]
	local from_function = type(source) == "function"
	if from_function then
		local keep = vim.tbl_map(function() return true end, wins)
		source = source({ mode = mode, visible = vim.tbl_keys(keep) })
	end
	local root = layout.parse(source, "layout." .. mode)
	local managed = {}
	for _, win in pairs(wins) do managed[win] = true end
	local ctx = {
		wins = wins,
		editors = vim.tbl_filter(function(win) return not managed[win] end, layout.tab_windows()),
	}
	local hidden = {}
	for _, leaf in ipairs(layout.leaves(root)) do
		if leaf.name ~= "editor" and not wins[leaf.name] then hidden[#hidden + 1] = leaf.name end
	end
	local measured = M.serialize(measure(root, ctx))
	layout.parse(measured, "captured layout." .. mode) -- must round-trip
	return { mode = mode, layout = measured, hidden = hidden, from_function = from_function }
end

---Format a capture for the user, as a Lua line for their `layout = { ... }`.
---@param result replconnect.LayoutCapture
---@return string
function M.describe(result)
	local lines = {
		("%s = [[ %s ]],"):format(result.mode, result.layout),
	}
	if #result.hidden > 0 then
		lines[#lines + 1] = ("Not open, so kept from your config: %s."):format(table.concat(result.hidden, ", "))
	end
	if result.from_function then
		lines[#lines + 1] = ("layout.%s is a function; this is the string it returned."):format(result.mode)
	end
	return table.concat(lines, "\n")
end

return M
