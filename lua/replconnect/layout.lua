-- Declarative pane layouts, in the spirit of Zellij layouts.
--
-- A layout string resembles its screen arrangement:
--
--   (editor @ 60% / repl) | (((plots \\ view) @ 30%) / vars) @ 35%
--
-- | is side by side, / is stacked, \\ declares layout-local alternatives.
-- @ sizes the preceding region along its parent split. Percentages are
-- shares of the enclosing region (the screen for the outermost one); bare
-- numbers are cells. Pane names are editor, repl, vars,
-- plots and view; "editor" stands for every window REPLConnect does not
-- manage and must appear exactly once.
--
-- Strings compile (layout_expr.lua) to an internal tree of { name = ... }
-- leaves and { dir = "row" | "col", children = ... } regions, plus the
-- layout's exclusive groups. Panes that are not shown are pruned, so one
-- string describes every
-- combination. Showing a pane moves the managed windows into the pruned tree
-- (`nvim_win_set_config`, so window handles and the terminal job survive).

local M = {}

M.PANES = { editor = true, repl = true, vars = true, plots = true, view = true }
M.MODES = { "horizontal", "vertical", "external" }
M.PANE_WIDTH = 60


-- Replacement history belongs to windows/tabs, not buffers: closing an active
-- exclusive pane restores the last valid alternative in that tab.
local histories, pending, revisions = {}, {}, {}
local window_options = { "wrap", "number", "relativenumber", "signcolumn", "foldcolumn", "winfixwidth", "winfixheight" }

local function remember(name, win, bufs, opts)
	local options = {}
	for _, key in ipairs(window_options) do options[key] = vim.wo[win][key] end
	return { name = name, buf = bufs[name], bufs = vim.tbl_extend("force", {}, bufs), opts = opts,
		view = vim.api.nvim_win_call(win, vim.fn.winsaveview), options = options }
end

---Forget replacement history on session teardown, before buffers are wiped.
function M.discard(buf)
	local function involves(stack)
		for _, item in ipairs(stack) do
			for _, b in pairs(item.bufs) do if b == buf then return true end end
		end
		return false
	end
	for win, history in pairs(histories) do
		if involves(history.stack) or (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
			histories[win] = nil
		end
	end
	for tab, item in pairs(pending) do
		if involves(item.stack) then pending[tab] = nil end
	end
end

local function restore_pending()
	local tab = vim.api.nvim_get_current_tabpage()
	local item = pending[tab]
	if not item then return end
	pending[tab] = nil
	if revisions[tab] ~= item.revision then return end
	local stack = item.stack
	while #stack > 0 do
		local previous = table.remove(stack)
		if vim.api.nvim_buf_is_valid(previous.buf) then
			local win = M.show(previous.name, previous.bufs, previous.opts)
			for key, value in pairs(previous.options) do vim.wo[win][key] = value end
			vim.api.nvim_win_call(win, function() vim.fn.winrestview(previous.view) end)
			histories[win] = { tab = tab, stack = stack }
			if previous.opts.on_restore then previous.opts.on_restore(previous.name) end
			return
		end
	end
end

vim.api.nvim_create_autocmd("WinClosed", {
	group = vim.api.nvim_create_augroup("replconnect.layout.history", { clear = true }),
	callback = function(args)
		local win = tonumber(args.match)
		local history = histories[win]
		histories[win] = nil
		if not history or #history.stack == 0 then return end
		pending[history.tab] = { stack = history.stack, revision = revisions[history.tab] }
		vim.schedule(restore_pending)
	end,
})
vim.api.nvim_create_autocmd("TabEnter", {
	group = "replconnect.layout.history", callback = function() vim.schedule(restore_pending) end,
})

---@class replconnect.LayoutNode
---@field name? string pane name (leaves)
---@field dir? "row" | "col" (containers)
---@field children? replconnect.LayoutNode[]
---@field size? number
---@field size_cells? boolean string @N is cells even when N = 1

---Leaves of `node` in order.
---@param node replconnect.LayoutNode
---@param out? replconnect.LayoutNode[]
---@return replconnect.LayoutNode[]
local function leaves(node, out)
	out = out or {}
	if node.name then
		out[#out + 1] = node
	else
		for _, child in ipairs(node.children) do
			leaves(child, out)
		end
	end
	return out
end

local EPSILON = 1e-9

---A short name for a region in messages: the pane, or its panes in brackets.
local function label(node)
	if node.name then return node.name end
	return "(" .. table.concat(vim.tbl_map(function(leaf) return leaf.name end, leaves(node)), " ") .. ")"
end

local function percent(fraction)
	return ("%g%%"):format(math.floor(fraction * 1000 + 0.5) / 10)
end

---Check that the percentage sizes of regions side by side (or stacked) fit
---the region that contains them. A percentage is a share of the enclosing
---region along its split (the root region is the screen), so the sibling
---percentages of every group are compared with 100%: over 100% does not fit,
---and when every sibling is sized they must fill it exactly; with unsized
---siblings they must leave them some room. A group containing a cell size
---(`@ 60`) is not summed, as that depends on the screen, but the groups
---inside it are still checked. Alternatives (`\\`) share one region and are
---not added up.
---@param root replconnect.LayoutNode
---@param path string
---@return string[] warnings
function M.check_sizes(root, path)
	local warnings = {}
	local function walk(node)
		if node.name or node.alternatives then return end
		local sum, unsized, cells, parts = 0, 0, false, {}
		for _, child in ipairs(node.children) do
			if child.size_cells then
				cells = true
			elseif child.size then
				sum = sum + child.size
				parts[#parts + 1] = ("%s %s"):format(label(child), percent(child.size))
			else
				unsized = unsized + 1
			end
		end
		if not cells and #parts > 0 then
			local where = ("%s: regions %s in %s total %s of it (%s)"):format(path,
				node.dir == "row" and "side by side" or "stacked", label(node), percent(sum), table.concat(parts, ", "))
			if sum > 1 + EPSILON then
				warnings[#warnings + 1] = where .. ", more than the 100% available"
			elseif unsized == 0 and sum < 1 - EPSILON then
				warnings[#warnings + 1] = ("%s, leaving %s unfilled; size one region less, or leave one unsized")
					:format(where, percent(1 - sum))
			elseif unsized > 0 and sum >= 1 - EPSILON then
				warnings[#warnings + 1] = ("%s, leaving no room for the %d unsized region(s)"):format(where, unsized)
			end
		end
		for _, child in ipairs(node.children) do walk(child) end
	end
	walk(root)
	return warnings
end

local warned = {}

---Report `check_sizes` warnings for a layout string, once per distinct string.
---@param source string
---@param root replconnect.LayoutNode
---@param path string
function M.warn_sizes(source, root, path)
	local key = path .. "\0" .. source
	if warned[key] then return end
	warned[key] = true
	for _, message in ipairs(M.check_sizes(root, path)) do
		vim.notify("replconnect: " .. message, vim.log.levels.WARN)
	end
end

M.leaves = leaves

---Compile and validate a layout string. Errors name the option and position.
---@param source any
---@param path? string
---@return replconnect.LayoutNode
---@return string[][] groups exclusive alternatives declared with \
function M.parse(source, path)
	path = path or "layout"
	if type(source) ~= "string" then
		error(("%s: expected a layout string, got %s"):format(path, type(source)), 0)
	end
	local root, groups = require("replconnect.layout_expr").parse(source, path)
	local seen = {}
	for _, leaf in ipairs(leaves(root)) do
		if not M.PANES[leaf.name] then
			error(("%s: unknown pane %q"):format(path, leaf.name), 0)
		end
		if seen[leaf.name] then
			error(("%s: pane %q appears more than once"):format(path, leaf.name), 0)
		end
		seen[leaf.name] = true
	end
	if not seen.editor then
		error(path .. ': must contain "editor"', 0)
	end
	return root, groups
end

---Drop panes not in `keep` ("editor" always stays). A container left with one
---child is replaced by it, which takes the container's size because it now
---sits in the container's parent.
---@param node replconnect.LayoutNode
---@param keep table<string, any>
---@return replconnect.LayoutNode?
function M.prune(node, keep)
	if node.name then
		return (node.name == "editor" or keep[node.name]) and node or nil
	end
	local children = {}
	for _, child in ipairs(node.children) do
		children[#children + 1] = M.prune(child, keep)
	end
	if #children == 0 then
		return nil
	elseif #children == 1 then
		local only = vim.tbl_extend("force", {}, children[1])
		only.size, only.size_cells = node.size, node.size_cells
		return only
	end
	return { dir = node.dir, size = node.size, size_cells = node.size_cells, children = children }
end

---Whether `node` contains the editor.
local function has_editor(node)
	for _, leaf in ipairs(leaves(node)) do
		if leaf.name == "editor" then
			return true
		end
	end
	return false
end

---Containers from the root down to the editor, each with the index of the
---child leading to it.
---@param root replconnect.LayoutNode
---@return { node: replconnect.LayoutNode, index: integer }[]
local function spine(root)
	local path, node = {}, root
	while not node.name do
		for i, child in ipairs(node.children) do
			if has_editor(child) then
				path[#path + 1] = { node = node, index = i }
				node = child
				break
			end
		end
	end
	return path
end

local SIDES = { row = { before = "left", after = "right" }, col = { before = "above", after = "below" } }

---Normal (non-floating) windows of the current tab.
---@return integer[]
function M.tab_windows()
	return vim.tbl_filter(function(win)
		return vim.api.nvim_win_get_config(win).relative == ""
	end, vim.api.nvim_tabpage_list_wins(0))
end

---Windows of the current tab showing each pane's buffer.
---@param bufs table<string, integer>
---@return table<string, integer>
function M.visible(bufs)
	local wins = {}
	local tab = M.tab_windows()
	for name, buf in pairs(bufs) do
		for _, win in ipairs(tab) do
			if vim.api.nvim_win_get_buf(win) == buf then
				wins[name] = win
				break
			end
		end
	end
	return wins
end

---For each window: `width`/`height` and whether it spans the tab horizontally
---(`full_width`, no row above it) and vertically (`full_height`).
---@return table<integer, { width: integer, height: integer, full_width: boolean, full_height: boolean }>
local function geometry()
	local out = {}
	local function walk(node, row, col)
		if node[1] == "leaf" then
			local win = node[2]
			out[win] = {
				width = vim.api.nvim_win_get_width(win),
				height = vim.api.nvim_win_get_height(win),
				full_width = not row,
				full_height = not col,
			}
			return
		end
		for _, child in ipairs(node[2]) do
			walk(child, row or node[1] == "row", col or node[1] == "col")
		end
	end
	walk(vim.fn.winlayout(), false, false)
	return out
end

---How the REPL is shown: the split it was launched with (stored in the buffer),
---else inferred from its window and remembered; "external" when not visible.
---@param repl_buf? integer
---@param repl_win? integer
---@return "horizontal" | "vertical" | "external"
function M.mode(repl_buf, repl_win)
	if not repl_buf or not repl_win then
		return "external"
	end
	local mode = vim.b[repl_buf].replconnect_layout
	if mode ~= "horizontal" and mode ~= "vertical" then
		mode = vim.api.nvim_win_get_width(repl_win) < vim.o.columns and "vertical" or "horizontal"
		vim.b[repl_buf].replconnect_layout = mode
	end
	return mode
end

---Cells for a default `size` along `dir`; fractions are relative to the screen.
local function cells(size, dir, literal_cells)
	if literal_cells or size > 1 then
		return math.floor(size)
	end
	local total = dir == "row" and vim.o.columns or (vim.o.lines - vim.o.cmdheight)
	return math.max(1, math.floor(size * total))
end

---Default size of an unsized pane along `dir`: `repl.size` along the
---terminal's split, `PANE_WIDTH` for side panes in a row.
local function default_size(name, dir, ctx)
	if name == "repl" then
		local along = ({ horizontal = "col", vertical = "row" })[ctx.mode]
		return dir == along and ctx.repl_size or nil
	end
	return dir == "row" and (name == "vars" or name == "plots" or name == "view") and M.PANE_WIDTH or nil
end

---Keep `node`'s windows from giving up room along `dir` while later nodes are
---sized; `release` restores the options.
local function pin(node, dir, ctx)
	local option = dir == "row" and "winfixwidth" or "winfixheight"
	for _, leaf in ipairs(leaves(node)) do
		local wins = leaf.name == "editor" and ctx.editors or { ctx.wins[leaf.name] }
		for _, win in ipairs(wins or {}) do
			ctx.pinned[#ctx.pinned + 1] = { win = win, option = option, value = vim.wo[win][option] }
			vim.wo[win][option] = true
		end
	end
end

local function release(ctx)
	for i = #ctx.pinned, 1, -1 do
		local p = ctx.pinned[i]
		if vim.api.nvim_win_is_valid(p.win) then
			vim.wo[p.win][p.option] = p.value
		end
	end
	ctx.pinned = {}
end

---Cells of a sized region within `total` cells of its parent region.
local function region_cells(node, total)
	if node.size_cells then return math.floor(node.size) end
	return math.max(1, math.floor(node.size * total))
end

---Region (cells along each axis) of each child of `node`, whose own region is
---`mine`. A percentage is a share of `mine` along the node's split; unsized
---children divide what the sized ones leave equally. The other axis is shared.
local function child_regions(node, mine)
	local axis = node.dir
	local cells, sized_total, unsized = {}, 0, 0
	for i, child in ipairs(node.children) do
		if child.size then
			cells[i] = region_cells(child, mine[axis])
			sized_total = sized_total + cells[i]
		else
			unsized = unsized + 1
		end
	end
	-- Neighbouring windows are divided by a separator (or status line) cell.
	local separators = #node.children - 1
	local share = unsized > 0 and math.max(1, math.floor((mine[axis] - sized_total - separators) / unsized)) or 0
	local regions = {}
	for i in ipairs(node.children) do
		regions[i] = { row = mine.row, col = mine.col }
		regions[i][axis] = cells[i] or share
	end
	return regions
end

local function set_extent(win, dir, cells)
	if dir == "row" then
		vim.api.nvim_win_set_width(win, cells)
	else
		vim.api.nvim_win_set_height(win, cells)
	end
end

---Give the unsized children of a group their equal share. The last unsized
---child absorbs the rounding, unless the group is a sized region along its own
---split, where nothing outside it can.
local function share_remainder(node, regions, ctx, exact)
	local unsized = {}
	for i, child in ipairs(node.children) do
		if not child.size then unsized[#unsized + 1] = i end
	end
	if not exact then table.remove(unsized) end
	for _, i in ipairs(unsized) do
		local child = node.children[i]
		local win = ctx.wins[leaves(child)[1].name]
		if win and not (child.children and child.dir == node.dir) then
			set_extent(win, node.dir, regions[i][node.dir])
			pin(child, node.dir, ctx)
		end
	end
end

---Explicit sizes win over remembered sizes. `mine` is the node's region in
---cells; a percentage is of the parent's region, never of the screen. A region
---sized along its own split has no single window to size, so its children are
---sized instead, filling it. Unsized siblings of a sized region share the rest
---equally rather than restoring a stale size (notably editor @ 60% / repl).
local function apply_sizes(node, dir, ctx, sized_parent, mine)
	local win = ctx.wins[leaves(node)[1].name]
	local own_axis = node.children and node.dir == dir
	if dir and win and not own_axis and (node.size or not sized_parent and not has_editor(node)) then
		local size = node.size and mine[dir]
		if not size then
			for _, leaf in ipairs(leaves(node)) do
				local before = ctx.before[ctx.wins[leaf.name]]
				if before and not (dir == "row" and before.full_width or dir == "col" and before.full_height) then
					size = dir == "row" and before.width or before.height
					break
				end
			end
		end
		if not size and node.name then
			local default = default_size(node.name, dir, ctx)
			size = default and cells(default, dir)
		end
		if size then
			set_extent(win, dir, size)
			pin(node, dir, ctx)
		end
	end
	if not node.children then return end
	local regions = child_regions(node, mine)
	local annotated = false
	for _, child in ipairs(node.children) do
		if child.size then annotated = true end
	end
	for i, child in ipairs(node.children) do
		apply_sizes(child, node.dir, ctx, annotated, regions[i])
	end
	if annotated or (own_axis and node.size) then
		share_remainder(node, regions, ctx, own_axis and node.size ~= nil)
	end
end

---Move pane `name`'s window (or open one for its buffer) as described by `config`.
local function place(name, config, ctx)
	local win = ctx.wins[name]
	if win then
		vim.api.nvim_win_set_config(win, config)
	else
		win = vim.api.nvim_open_win(ctx.bufs[name], false, config)
		ctx.wins[name] = win
	end
	return win
end

---Arrange an editor-free subtree, whose first pane is already in `win`, by
---splitting along its direction and then recursing into each child.
local function build(node, win, ctx)
	if node.name then
		return
	end
	local wins = { win }
	for i = 2, #node.children do
		local name = leaves(node.children[i])[1].name
		wins[i] = place(name, { split = SIDES[node.dir].after, win = wins[i - 1] }, ctx)
	end
	for i, child in ipairs(node.children) do
		build(child, wins[i], ctx)
	end
end

---Move every managed window into `root`. Siblings of the editor are placed as
---top-level splits from the innermost level outwards, so outer levels wrap
---inner ones; editor-free subtrees are built by splitting their first window.
---@param root replconnect.LayoutNode pruned tree
---@param ctx { bufs: table<string, integer>, wins: table<string, integer>, mode: string, repl_size?: number, before: table }
function M.arrange(root, ctx)
	local levels = spine(root)
	for level = #levels, 1, -1 do
		local node, index = levels[level].node, levels[level].index
		local function top(i, side)
			local child = node.children[i]
			build(child, place(leaves(child)[1].name, { split = side, win = -1 }, ctx), ctx)
		end
		for i = index + 1, #node.children do
			top(i, SIDES[node.dir].after)
		end
		for i = index - 1, 1, -1 do
			top(i, SIDES[node.dir].before)
		end
	end
	ctx.pinned = {}
	apply_sizes(root, nil, ctx, false, { row = vim.o.columns, col = vim.o.lines - vim.o.cmdheight })
	release(ctx)
end

---Compile a mode's layout (calling it first if it is a function); returns the
---tree and its exclusive groups.
local function resolve(layouts, mode, keep)
	local source = layouts[mode]
	if type(source) == "function" then
		source = source({ mode = mode, visible = vim.tbl_keys(keep) })
	end
	local root, groups = M.parse(source, "layout." .. mode)
	M.warn_sizes(source, root, "layout." .. mode)
	return root, groups
end

---Whether an exclusive alternative is visible (used to avoid background
---plot notifications replacing an explicitly opened viewer).
function M.blocked(target, bufs)
	local wins = M.visible(bufs)
	local keep = vim.tbl_map(function() return true end, wins)
	keep[target] = true
	local _, groups = resolve(require("replconnect.config").options.layout, M.mode(bufs.repl, wins.repl), keep)
	for _, group in ipairs(groups) do
		if vim.tbl_contains(group, target) then
			for _, name in ipairs(group) do
				if name ~= target and wins[name] then return true end
			end
		end
	end
	return false
end

---Close the other visible members of `target`\'s exclusive groups.
local function hide_exclusive(target, groups, wins, bufs, opts)
	local stack = {}
	for _, group in ipairs(groups or {}) do
		if vim.tbl_contains(group, target) then
			for _, name in ipairs(group) do
				if name ~= target and wins[name] then
					local win = wins[name]
					local history = histories[win]
					histories[win] = nil -- replacement must not itself trigger restoration
					vim.list_extend(stack, history and history.stack or {})
					stack[#stack + 1] = remember(name, win, bufs, opts)
					if opts.hide and opts.hide[name] then
						opts.hide[name]()
					elseif vim.api.nvim_win_is_valid(wins[name]) then
						vim.api.nvim_win_close(wins[name], true)
					end
					wins[name] = nil
				end
			end
		end
	end
	-- Repeated switching must not create a cycle or an unbounded history.
	return vim.tbl_filter(function(item) return item.name ~= target end, stack)
end

---@class replconnect.LayoutShowOpts
---@field mode? "horizontal" | "vertical" | "external" default: from the REPL window
---@field layouts? replconnect.LayoutConfig default: `config.options.layout`
---@field hide? table<string, fun()> how to hide a pane replaced by an exclusive one
---@field repl_size? number default terminal size along its split; default `repl.size`
---@field on_restore? fun(name: string) redraw a restored pane

---Show pane `target` and arrange the managed panes per the layout for the
---current mode. Returns the target's window without focusing it.
---@param target string
---@param bufs table<string, integer> buffer of each managed pane, including `target`
---@param opts? replconnect.LayoutShowOpts
---@return integer win
function M.show(target, bufs, opts)
	opts = opts or {}
	local layouts = opts.layouts or require("replconnect.config").options.layout
	local wins = M.visible(bufs)
	local tab = vim.api.nvim_get_current_tabpage()
	revisions[tab] = (revisions[tab] or 0) + 1
	pending[tab] = nil
	if wins[target] then
		return wins[target]
	end
	local mode = opts.mode or M.mode(bufs.repl, wins.repl)
	local keep = vim.tbl_map(function() return true end, wins)
	keep[target] = true
	local root, groups = resolve(layouts, mode, keep)
	local stack = hide_exclusive(target, groups, wins, bufs, opts)
	keep = vim.tbl_map(function() return true end, wins)
	keep[target] = true
	if not vim.tbl_contains(vim.tbl_map(function(l) return l.name end, leaves(root)), target) then
		-- A pane missing from the layout goes to the right of everything.
		root = { dir = "row", children = { root, { name = target } } }
	end
	root = M.prune(root, keep) --[[@as replconnect.LayoutNode]]

	local managed = {}
	for _, win in pairs(wins) do
		managed[win] = true
	end
	local editor = vim.tbl_filter(function(win) return not managed[win] end, M.tab_windows())
	if #editor == 0 then
		-- Nothing left to arrange around: open next to the current window.
		local win = vim.api.nvim_open_win(bufs[target], false, { split = "right", win = 0 })
		histories[win] = { tab = tab, stack = stack }
		return win
	end

	local ctx = {
		bufs = bufs,
		wins = wins,
		mode = mode,
		repl_size = opts.repl_size or require("replconnect.config").options.repl.size,
		before = geometry(),
		editors = editor,
	}
	ctx.wins.editor = editor[1]
	M.arrange(root, ctx)
	histories[ctx.wins[target]] = { tab = tab, stack = stack }
	return ctx.wins[target]
end

return M
