-- nvim --headless -u NONE -l tests/layout_capture.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local config = require("replconnect.config")
local layout = require("replconnect.layout")
local capture = require("replconnect.layout_capture")
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end
local function near(a, b, tolerance, what)
	assert(math.abs(a - b) <= (tolerance or 1), ("%s: %s not within %s of %s"):format(what or "value", a, tolerance or 1, b))
end

-- Serialization round-trips, with parentheses only where needed.
for _, source in ipairs({
	"editor",
	"editor | vars @ 35%",
	"(editor @ 60% / repl) | ((plots \\ view) @ 30% / vars) @ 35%",
	"repl @ 30% | editor | ((plots \\ view) / vars) @ 25%",
	"editor | (vars / plots / view) @ 60",
	"(editor | vars | (plots \\ view)) / repl @ 30%",
	"editor / (repl | vars) @ 30%",
	"editor | (vars | plots) @ 40%", -- a row nested in a row keeps its group
	"editor / ((vars / plots) / repl)",
	"editor | vars @ 12.5%",
}) do
	local tree = layout.parse(source)
	local again = layout.parse(capture.serialize(tree))
	eq(again, tree)
end
eq(capture.serialize((layout.parse("((editor) | (vars))"))), "editor | vars")
eq(capture.serialize((layout.parse("(((plots \\ view) @ 30%) / vars) @ 35% | editor"))),
	"((plots \\ view) @ 30% / vars) @ 35% | editor")

-- Only the width is changed: headless Neovim does not refit the window layout
-- to a new 'lines', which would make the screen height disagree with the
-- windows. The default 24 rows are enough for the heights used below.
vim.o.columns = 240
local editor = vim.api.nvim_get_current_win()
local bufs = {}
for _, name in ipairs({ "vars", "plots", "view" }) do bufs[name] = vim.api.nvim_create_buf(false, true) end
local function reset(external)
	for _, buf in pairs(bufs) do layout.discard(buf) end
	vim.api.nvim_set_current_win(editor)
	vim.cmd("silent! only!")
	config.set({ layout = { external = external } })
end
local function captured() return layout.parse(capture.capture(bufs).layout) end

-- Manual resizes are captured as percentages of the containing region.
reset([[editor | ((plots \ view) @ 30% / vars) @ 40%]])
layout.show("vars", bufs)
local plots = layout.show("plots", bufs)
vim.api.nvim_win_set_width(plots, 120) -- the column: half the screen
vim.api.nvim_win_set_height(plots, 8)
local result = capture.capture(bufs)
eq(result.mode, "external")
eq(result.hidden, { "view" })
assert(result.layout:find("^editor | %(%(plots \\ view%) @ %d+%% / vars%) @ %d+%%$"), result.layout)
local tree = captured()
near(tree.children[2].size * 100, 50, 1, "column width %")
local column_height = vim.api.nvim_win_get_height(plots) + 1 + vim.api.nvim_win_get_height(vim.fn.bufwinid(bufs.vars))
near(tree.children[2].children[1].size * 100, math.floor(8 / column_height * 100 + 0.5), 0.001, "plots height %")
assert(tree.children[1].size == nil, "the region with the editor takes the remainder")
eq(layout.check_sizes(tree, "captured"), {})
-- Applying the capture reproduces the arrangement.
config.set({ layout = { external = result.layout } })
for _, buf in pairs(bufs) do layout.discard(buf) end
vim.api.nvim_set_current_win(editor)
vim.cmd("silent! only!")
layout.show("vars", bufs)
plots = layout.show("plots", bufs)
near(vim.api.nvim_win_get_width(plots), 120, 2, "re-applied width")
near(vim.api.nvim_win_get_height(plots), 8, 2, "re-applied height (captured " .. result.layout .. ")")

-- A region configured in cells is captured in cells.
reset([[editor | (vars / plots) @ 60]])
layout.show("vars", bufs)
vim.api.nvim_win_set_width(layout.show("plots", bufs), 80)
tree = captured()
eq(tree.children[2].size, 80)
assert(tree.children[2].size_cells, "cell sizes stay cells")
assert(capture.capture(bufs).layout:find("@ 80$"), capture.capture(bufs).layout)

-- Panes that are not open keep their configured size.
reset([[editor | vars @ 20% | plots @ 25%]])
vim.api.nvim_win_set_width(layout.show("vars", bufs), 48)
result = capture.capture(bufs)
eq(result.hidden, { "plots" })
tree = layout.parse(result.layout)
near(tree.children[2].size * 100, 20, 1, "vars %")
eq(tree.children[3].size, 0.25)

-- Without the editor among siblings, the last visible region is the remainder.
reset([[editor | (vars @ 30% / plots @ 70%) @ 40%]])
layout.show("vars", bufs)
layout.show("plots", bufs)
tree = captured()
assert(tree.children[2].children[1].size and not tree.children[2].children[2].size, vim.inspect(tree))

-- :REPLLayout! copies the line and applies it for the session only.
reset([[editor | vars @ 20%]])
vim.api.nvim_win_set_width(layout.show("vars", bufs), 72)
local plugin = require("replconnect")
local original_notify, message = vim.notify, nil
vim.notify = function(msg) message = msg end
-- the plugin finds panes through its own state; drive the capture with ours
local real = capture.capture
capture.capture = function() return real(bufs) end
result = plugin.capture_layout(true)
capture.capture = real
vim.notify = original_notify
eq(config.options.layout.external, result.layout)
eq(vim.fn.getreg('"'), ("external = [[ %s ]],"):format(result.layout))
assert(message:find("rest of this session", 1, true), message)
near(layout.parse(result.layout).children[2].size * 100, 30, 1, "applied vars %")

reset(nil)
for _, buf in pairs(bufs) do vim.api.nvim_buf_delete(buf, { force = true }) end
print("layout capture tests passed")
