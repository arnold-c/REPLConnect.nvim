-- nvim --headless -u NONE -l tests/layout_expr.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local layout = require("replconnect.layout")
local config = require("replconnect.config")
local repl = require("replconnect.repl")
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end
local function fails(source, message)
	local ok, err = pcall(layout.parse, source, "layout.horizontal")
	assert(not ok and tostring(err):find(message, 1, true), tostring(err))
	assert(tostring(err):find("layout.horizontal", 1, true))
end

-- Strings compile to the internal tree.
eq(layout.parse("(editor | vars | plots) / repl"), { dir = "col", children = {
	{ dir = "row", children = { { name = "editor" }, { name = "vars" }, { name = "plots" } } },
	{ name = "repl" },
} })
-- Precedence: @, alternatives, /, |. Whitespace and newlines are immaterial.
local root, groups = layout.parse([[
  (editor @ 60% / repl) | (((plots \ view) @ 30%) / vars) @ 35%
]])
eq(groups, { { "plots", "view" } })
eq(root, {
	dir = "row", children = {
		{ dir = "col", children = { { name = "editor", size = 0.6 }, { name = "repl" } } },
		{ dir = "col", size = 0.35, children = {
			{ dir = "col", size = 0.3, alternatives = true, children = { { name = "plots" }, { name = "view" } } },
			{ name = "vars" },
		} },
	},
})
eq(layout.parse("editor | vars / plots").children[2].dir, "col")
local _, three = layout.parse([[editor | (plots \ view \ vars)]])
eq(three, { { "plots", "view", "vars" } })
local _, nested = layout.parse([[editor | ((plots \ view) \ vars)]])
eq(nested, three)
-- @1 is one cell, not 100%; explicit % distinguishes it from @100%.
eq(layout.parse("editor | vars @ 1").children[2], { name = "vars", size = 1, size_cells = true })
eq(layout.parse("editor | vars @ 100%").children[2], { name = "vars", size = 1 })
eq(layout.parse("editor | vars @ .5%").children[2].size, 0.005)
for _, case in ipairs({
	{ "", "expected name" }, { "editor |", "expected name" },
	{ "(editor / repl", "expected )" }, { "editor vars", "expected end" },
	{ "editor + vars", "unexpected character" }, { "editor | unknown", "unknown pane" },
	{ "editor | editor", "appears more than once" }, { "plots / vars", 'must contain "editor"' },
	{ "editor | vars @ 0%", "positive" }, { "editor | vars @ 101%", "at most 100%" },
	{ "editor | vars @ 1.5", "integer" }, { "editor | vars @ 30% @ 40%", "expected end" },
	{ [[editor \ plots]], "alternatives must" },
	{ [[editor | (plots \ (view / vars))]], "alternatives must" },
	{ [[editor | (plots \ view @ 30%)]], "size the whole" },
}) do fails(case[1], case[2]) end
-- Size checks: percentages are of the screen and must fit their parent's share.
local function warnings(source) return layout.check_sizes(layout.parse(source), "layout.vertical") end
local over = warnings([[repl @ 30% | editor @ 80% | ((plots \ view) / vars) @ 25%]])
eq(#over, 1)
assert(over[1]:find("total 135%", 1, true) and over[1]:find("more than the 100% available", 1, true), over[1])
assert(over[1]:find("layout.vertical", 1, true) and over[1]:find("editor 80%", 1, true), over[1])
local under = warnings([[repl @ 30% | editor @ 50%]])
assert(#under == 1 and under[1]:find("leaving 20% unfilled", 1, true), under[1])
local crowded = warnings([[repl @ 30% | editor @ 70% | vars]])
assert(#crowded == 1 and crowded[1]:find("no room for the 1 unsized", 1, true), crowded[1])
-- unsized regions take the remainder; exact fills and cell sizes are fine
eq(warnings([[repl @ 30% | editor | vars @ 25%]]), {})
eq(warnings([[repl @ 30% | editor @ 70%]]), {})
eq(warnings([[repl @ 30 | editor @ 90% | vars]]), {}) -- a cell size disables the group check
-- nested percentages are shares of their own region, which must be filled
local nested = warnings([[editor | (vars @ 30% | plots @ 30%) @ 50%]])
assert(#nested == 1 and nested[1]:find("total 60% of it", 1, true) and nested[1]:find("leaving 40% unfilled", 1, true), nested[1])
local nested_over = warnings([[editor | (vars @ 60% | plots @ 60%) @ 50%]])
assert(#nested_over == 1 and nested_over[1]:find("more than the 100% available", 1, true), nested_over[1])
eq(warnings([[editor | (vars @ 30% | plots @ 70%) @ 50%]]), {})
eq(warnings([[editor | (vars @ 30% | plots) @ 50%]]), {})
-- the region's own size does not matter to its children's check
eq(warnings([[editor | (vars @ 60% | plots) | repl @ 20%]]), {})
-- groups inside a cell-sized group are still checked
local in_cells = warnings([[editor | (vars @ 30% | plots @ 30%) @ 40]])
assert(#in_cells == 1 and in_cells[1]:find("leaving 40% unfilled", 1, true), in_cells[1])
-- stacking is checked on the height axis independently of widths
eq(warnings([[(editor @ 60% / repl) | ((plots \ view) @ 30% / vars) @ 35%]]), {})
assert(#warnings([[(editor @ 60% / repl @ 60%) | vars]]) == 1)
-- alternatives share one region and are never added up
eq(warnings([[editor | (plots \ view) @ 40%]]), {})
-- setup warns once per layout string
local notified = {}
local original_notify = vim.notify
vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
config.set({ layout = { vertical = [[repl @ 30% | editor @ 80% | vars @ 25%]] } })
config.set({ layout = { vertical = [[repl @ 30% | editor @ 80% | vars @ 25%]] } })
vim.notify = original_notify
eq(#notified, 1)
assert(notified[1].level == vim.log.levels.WARN and notified[1].msg:find("135%", 1, true))
config.set()

-- Keep the README recipes executable: parse every layout long string shown there.
local readme = table.concat(vim.fn.readfile("README.md"), "\n")
local examples = 0
for expression in readme:gmatch("%[%[(.-)%]%]") do
	if expression:find("editor", 1, true) then
		local tree = layout.parse(expression, "README layout example")
		eq(layout.check_sizes(tree, "README"), {}) -- recipes must not trip size warnings
		examples = examples + 1
	end
end
assert(examples >= 10, "README layout recipes were not checked")
config.set({ layout = { horizontal = "editor / repl", external = [[editor | (plots \ view)]] } })
eq(config.options.layout.external, [[editor | (plots \ view)]])

-- Real windows: local exclusivity, restoration, sizing, and mode independence.
vim.o.columns, vim.o.lines = 240, 60
local editor = vim.api.nvim_get_current_win()
local bufs = {}
for _, name in ipairs({ "repl", "vars", "plots", "view" }) do bufs[name] = vim.api.nvim_create_buf(false, true) end
config.set({ layout = {
	horizontal = [[(editor @ 60% / repl) | (((plots \ view) @ 30%) / vars) @ 35%]],
	vertical = [[repl | editor | (plots / view / vars) @ 35%]],
	external = [[editor | (plots / view / vars) @ 35%]],
} })
local term = repl.open_split({ split = "horizontal" }, bufs.repl)
vim.api.nvim_set_current_win(editor)
layout.show("vars", bufs)
local plots = layout.show("plots", bufs)
assert(vim.api.nvim_win_get_width(plots) == math.floor(vim.o.columns * 0.35))
assert(vim.api.nvim_win_get_height(plots) == math.floor((vim.o.lines - vim.o.cmdheight) * 0.3))
assert(vim.api.nvim_win_get_height(editor) == math.floor((vim.o.lines - vim.o.cmdheight) * 0.6))
assert(vim.api.nvim_win_get_position(term)[1] > vim.api.nvim_win_get_position(editor)[1])
assert(layout.blocked("view", bufs), "horizontal alternatives are local exclusive")
local viewer = layout.show("view", bufs)
assert(vim.fn.bufwinid(bufs.plots) == -1)
assert(vim.api.nvim_win_get_height(viewer) == math.floor((vim.o.lines - vim.o.cmdheight) * 0.3))
vim.api.nvim_win_close(viewer, true)
assert(vim.wait(1000, function() return vim.fn.bufwinid(bufs.plots) ~= -1 end), "closing view restores plots")

-- The same pair can be simultaneous in a different mode, without global groups.
layout.discard(bufs.plots)
vim.api.nvim_set_current_win(editor)
vim.cmd("silent! only!")
term = repl.open_split({ split = "vertical" }, bufs.repl)
layout.show("plots", bufs)
assert(not layout.blocked("view", bufs))
layout.show("view", bufs)
assert(vim.fn.bufwinid(bufs.plots) ~= -1 and vim.fn.bufwinid(bufs.view) ~= -1)
layout.discard(bufs.plots)
vim.api.nvim_set_current_win(editor)
vim.cmd("silent! only!")
layout.show("plots", bufs)
assert(not layout.blocked("view", bufs), "external layout has no alternatives")
layout.show("view", bufs)
assert(vim.fn.bufwinid(bufs.plots) ~= -1 and vim.fn.bufwinid(bufs.view) ~= -1)

-- Functions may return strings, with the same mode-local alternative policy.
local context
config.set({ layout = { external = function(ctx)
	context = ctx
	return [[editor | (plots \ view)]]
end } })
assert(layout.blocked("view", bufs))
assert(context.mode == "external" and vim.tbl_contains(context.visible, "view"))

-- A nested percentage is of its own region, not of the screen:
-- (vars | plots @ 25%) @ 40% -> region 40% of the width, plots a quarter of that.
config.set({ layout = { external = [[editor | (vars | plots @ 25%) @ 40%]] } })
for _, buf in pairs(bufs) do layout.discard(buf) end
vim.api.nvim_set_current_win(editor)
vim.cmd("silent! only!")
layout.show("vars", bufs)
plots = layout.show("plots", bufs)
local region = math.floor(vim.o.columns * 0.4)
eq(vim.api.nvim_win_get_width(plots), math.floor(region * 0.25))
assert(math.abs(vim.api.nvim_win_get_width(vim.fn.bufwinid(bufs.vars)) - (region - math.floor(region * 0.25))) <= 1)

-- Unsized regions divide what the sized ones leave equally.
for _, buf in pairs(bufs) do layout.discard(buf) end
vim.api.nvim_set_current_win(editor)
vim.cmd("silent! only!")
config.set({ layout = { external = [[editor | vars | plots @ 40%]] } })
layout.show("vars", bufs)
plots = layout.show("plots", bufs)
assert(vim.api.nvim_win_get_width(plots) == math.floor(vim.o.columns * 0.4))
local left, middle = vim.api.nvim_win_get_width(editor), vim.api.nvim_win_get_width(vim.fn.bufwinid(bufs.vars))
assert(math.abs(left - middle) <= 1, ("editor %d, vars %d"):format(left, middle))

for _, buf in pairs(bufs) do layout.discard(buf); vim.api.nvim_buf_delete(buf, { force = true }) end
config.set()
print("layout expression tests passed")
