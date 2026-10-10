-- Run from the repository root: nvim --headless -u NONE -l tests/layout.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local config = require("replconnect.config")
local layout = require("replconnect.layout")
local repl = require("replconnect.repl")

local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end
local function fails(fn, pattern)
	local ok, err = pcall(fn)
	assert(not ok, "expected an error matching " .. pattern)
	assert(tostring(err):find(pattern, 1, true), tostring(err))
end

-- parse: layout strings compile to the internal tree; errors name the option
eq(layout.parse("editor / repl @ 7"), {
	dir = "col", children = { { name = "editor" }, { name = "repl", size = 7, size_cells = true } },
})
fails(function() layout.parse("vars / plots") end, 'must contain "editor"')
fails(function() layout.parse("editor | editor") end, "appears more than once")
fails(function() layout.parse("editor | varz", "layout.x") end, "layout.x: unknown pane")
fails(function() layout.parse({ "editor" }, "layout.horizontal") end, "expected a layout string")

-- prune: hidden panes go, single-child regions collapse and pass on their size
local tree = layout.parse("editor | (vars / plots) @ 60")
eq(layout.prune(tree, { vars = true }), { dir = "row", children = {
	{ name = "editor" }, { name = "vars", size = 60, size_cells = true },
} })
eq(layout.prune(tree, {}), { name = "editor" })
eq(layout.prune(tree, { vars = true, plots = true }), tree)

-- config: strings replace the defaults and are validated at setup
config.set({ layout = { horizontal = "editor / repl" } })
eq(config.options.layout.horizontal, "editor / repl")
eq(config.options.layout.vertical, "editor | (vars / plots / view / repl)")
fails(function() config.set({ layout = { vertical = "vars | plots" } }) end, "layout.vertical")
-- unknown layout options fail loudly
fails(function() config.set({ layout = { horizntal = "editor" } }) end, "layout.horizntal is not an option")
-- layouts put under `repl` by mistake are reported, not silently ignored
local original_notify, warned = vim.notify, nil
vim.notify = function(msg) warned = msg end
config.set({ repl = { horizontal = "editor / repl" } })
vim.notify = original_notify
assert(warned and warned:find("repl.horizontal is ignored", 1, true), warned)
config.set()

-- Arranging real windows. Pane buffers stand in for the terminal and panes.
-- Headless Neovim is 80x24; leave room for an editor beside two side panes.
vim.o.columns, vim.o.lines = 240, 60
local editor = vim.api.nvim_get_current_win()
local bufs = {
	repl = vim.api.nvim_create_buf(false, true),
	vars = vim.api.nvim_create_buf(false, true),
	plots = vim.api.nvim_create_buf(false, true),
}

---The current tab as a layout tree of pane names; other windows are "editor".
---Nested containers of the same direction are flattened.
local function shape()
	local names = {}
	for name, buf in pairs(bufs) do
		names[buf] = name
	end
	local function walk(node)
		if node[1] == "leaf" then
			return names[vim.api.nvim_win_get_buf(node[2])] or "editor"
		end
		local out = { node[1] }
		for _, child in ipairs(node[2]) do
			local sub = walk(child)
			if type(sub) == "table" and sub[1] == node[1] then
				vim.list_extend(out, sub, 2)
			else
				out[#out + 1] = sub
			end
		end
		return out
	end
	return walk(vim.fn.winlayout())
end

local function reset(opts)
	vim.api.nvim_set_current_win(editor)
	vim.cmd("silent! only!")
	config.set(opts)
end

local function start_repl(split, size)
	local win = repl.open_split({ split = split, size = size }, bufs.repl)
	vim.api.nvim_set_current_win(editor)
	return win
end

local function show(name, extra)
	local present = { repl = bufs.repl }
	for _, n in ipairs(extra or {}) do
		present[n] = bufs[n]
	end
	present[name] = bufs[name]
	return layout.show(name, present, { hide = extra and extra.hide })
end

-- default horizontal: panes beside the editor, terminal full width, sizes kept
reset()
local term = start_repl("horizontal", 7)
eq(shape(), { "col", "editor", "repl" })
local vars = show("vars")
eq(shape(), { "col", { "row", "editor", "vars" }, "repl" })
vim.api.nvim_win_set_width(vars, 50) -- a user resize survives later arrangements
local plots = show("plots", { "vars" })
eq(shape(), { "col", { "row", "editor", "vars", "plots" }, "repl" })
assert(vim.api.nvim_win_is_valid(term) and vim.api.nvim_win_is_valid(vars), "windows are moved, not replaced")
eq(vim.api.nvim_win_get_height(term), 7)
eq(vim.api.nvim_win_get_width(vars), 50)
eq(vim.api.nvim_win_get_width(plots), layout.PANE_WIDTH)
eq(vim.api.nvim_get_current_win(), editor)
eq(show("vars", { "plots" }), vars) -- already visible: nothing moves
eq(shape(), { "col", { "row", "editor", "vars", "plots" }, "repl" })

-- stacked beside the editor, plots on top, whichever opens first
reset({ layout = { horizontal = "(editor | (plots / vars)) / repl" } })
start_repl("horizontal", 7)
show("vars")
eq(shape(), { "col", { "row", "editor", "vars" }, "repl" })
show("plots", { "vars" })
eq(shape(), { "col", { "row", "editor", { "col", "plots", "vars" } }, "repl" })

-- side panes in the terminal's row
reset({ layout = { horizontal = "editor / (repl | vars | plots)" } })
term = start_repl("horizontal", 7)
show("plots")
show("vars", { "plots" })
eq(shape(), { "col", "editor", { "row", "repl", "vars", "plots" } })
eq(vim.api.nvim_win_get_height(term), 7)
eq(vim.b[bufs.repl].replconnect_layout, "horizontal") -- not re-inferred from its narrower window

-- alternatives: one pane replaces the other, through the pane's own hide
local hidden = {}
reset({ layout = { horizontal = [[(editor | (vars \ plots)) / repl]] } })
start_repl("horizontal", 7)
show("vars")
show("plots", { "vars", hide = { vars = function()
	hidden[#hidden + 1] = "vars"
	vim.api.nvim_win_close(vim.fn.bufwinid(bufs.vars), true)
end } })
eq(hidden, { "vars" })
eq(shape(), { "col", { "row", "editor", "plots" }, "repl" })

-- default vertical: panes above the terminal in its column, which keeps its width
reset()
term = start_repl("vertical", 30)
show("vars")
show("plots", { "vars" })
eq(shape(), { "row", "editor", { "col", "vars", "plots", "repl" } })
eq(vim.api.nvim_win_get_width(term), 30)

-- external REPL (no terminal in this tab): a 60-column stack on the right
reset()
vars = show("vars")
show("plots", { "vars" })
eq(shape(), { "row", "editor", { "col", "vars", "plots" } })
eq(vim.api.nvim_win_get_width(vars), 60)

-- a function layout sees the mode and the panes to show
local seen
reset({ layout = { external = function(ctx)
	seen = ctx
	return "editor / vars"
end } })
show("vars")
eq(seen.mode, "external")
eq(seen.visible, { "vars" })
eq(shape(), { "col", "editor", "vars" })

-- a pane missing from the layout still opens, to the right
reset({ layout = { external = "editor | vars" } })
show("plots")
eq(shape(), { "row", "editor", "plots" })

-- the user's own editor splits stay together and are never moved apart
reset()
vim.cmd("vsplit")
local second = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(editor)
start_repl("horizontal", 7)
show("vars")
eq(shape(), { "col", { "row", "editor", "editor", "vars" }, "repl" })
assert(vim.api.nvim_win_is_valid(second))

-- a terminal opened by the user is classified by its window, then remembered
reset()
vim.b[bufs.repl].replconnect_layout = nil
vim.api.nvim_open_win(bufs.repl, false, { split = "right", win = -1, width = 30 })
show("vars")
eq(vim.b[bufs.repl].replconnect_layout, "vertical")
eq(shape(), { "row", "editor", { "col", "vars", "repl" } })

reset()
print("layout tests passed")
