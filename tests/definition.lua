-- Run from the repository root: nvim --headless -u NONE -l tests/definition.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns, vim.o.lines = 200, 60
require("replconnect.config").set({ completion = false })
local definition = require("replconnect.definition")
local view = require("replconnect.view")

local function flush() vim.wait(50, function() return false end) end

-- Capture notifications instead of printing them.
local notes = {}
vim.notify = function(message, level) notes[#notes + 1] = { message = message, level = level } end
local function noted(text)
	return vim.iter(notes):any(function(n) return n.message:find(text, 1, true) ~= nil end)
end

-- A source file with two functions.
local file = vim.fn.tempname() .. ".jl"
vim.fn.writefile({
	"function f(x)", -- 1
	"    x + 1", -- 2
	"end", -- 3
	"", -- 4
	"g(x) = 2x", -- 5
}, file)
local mtime = vim.uv.fs_stat(file).mtime.sec

-- A fake client answering `definition` from `locations`.
local calls, locations = {}, {}
local client = { language = "julia", pid = 1, info = { capabilities = { "definition" } } }
function client:request(method, params, on_result)
	calls[#calls + 1] = { method = method, params = params }
	on_result({ locations = locations })
end

-- symbol names: plain, qualified, with a signature
assert(definition.symbol_matches("f", "f"))
assert(definition.symbol_matches("Main.f", "f"))
assert(definition.symbol_matches("f(x::Int)", "f"))
assert(not definition.symbol_matches("ff", "f"))

-- anchors: the line naming the function, skipping cell markers and comments
assert(definition.anchor("#%%\n# adds\nfunction t(x, y)\n    x + y\nend", "t") == "function t(x, y)")
assert(definition.anchor("\n  @kw x = 1", "t") == "@kw x = 1")

-- code sent from a loaded buffer is found by its source
local sent = vim.fn.tempname() .. ".jl"
vim.fn.writefile({ "#%%", "function t(x, y)", "    x + y", "end", "", "t(x) = 20x" }, sent)
vim.cmd.badd(vim.fn.fnameescape(sent))
local sent_buf = vim.fn.bufnr(sent)
vim.fn.bufload(sent_buf)
vim.bo[sent_buf].filetype = "julia"
local found = definition.find_in_buffers({
	{ signature = "t(x, y)", file = "REPL[1]", line = 1, source = "#%%\nfunction t(x, y)\n    x + y\nend" },
	{ signature = "t(x)", file = "REPL[2]", line = 1, source = "t(x) = 20x" },
	{ signature = "t()", file = "REPL[3]", line = 1 },
}, { "julia" }, "t")
assert(#found == 2, vim.inspect(found))
assert(found[1].line == 2 and found[2].line == 6 and found[1].file == vim.api.nvim_buf_get_name(sent_buf))

-- staleness: source compared with the file's line, else the file's mtime
assert(not definition.stale({ file = file, line = 1, source = "function f(x)\n    x + 1\nend" }))
assert(definition.stale({ file = file, line = 2, source = "function f(x)" }), "line moved")
assert(not definition.stale({ file = file, line = 5, source = "g(x) = 2x" }))
assert(not definition.stale({ file = file, line = 1, mtime = mtime }))
assert(definition.stale({ file = file, line = 1, mtime = mtime - 10 }), "file saved after loading")
assert(not definition.stale({ file = "REPL[3]", line = 1, source = "h() = 1" }), "no file to compare")

-- render: source as sent, else a file excerpt up to the first blank line
local lines = definition.render("f", {
	{ signature = "f(x)", file = file, line = 1 },
	{ signature = "f()", file = "REPL[2]", line = 1, source = "f() = 0" },
	{ signature = "f(x, y)" },
}, "julia")
local text = table.concat(lines, "\n")
assert(lines[1]:find("f: 3 methods", 1, true), lines[1])
assert(text:find("function f(x)\n    x + 1\nend", 1, true), text)
assert(not text:find("g(x)", 1, true), "excerpt stops at the blank line")
assert(text:find("REPL[2]:1", 1, true) and text:find("f() = 0", 1, true), text)
assert(text:find("source unavailable", 1, true), text)
assert(lines[3]:match("^#"), "signatures are comments: " .. lines[3])
assert(definition.render("g", { { signature = "g(x)", file = file, line = 2, source = "g(x) = 2x" } }, "julia")[4]
	:find("may be out of date", 1, true))

-- v: methods appear in the viewer, read-only, with only `close` bound
local editor = vim.api.nvim_get_current_win()
locations = { { signature = "f(x)", file = file, line = 1, source = "function f(x)\n    x + 1\nend" } }
definition.view(client, { "f" }, "f")
flush()
assert(calls[#calls].method == "definition" and vim.deep_equal(calls[#calls].params.path, { "f" }))
local buf = view.buffer(client)
assert(buf and vim.api.nvim_get_current_buf() == buf, "viewer is shown and focused")
local shown = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(shown:find("x + 1", 1, true), shown)
assert(not vim.bo[buf].modifiable and vim.bo[buf].filetype == "inspectview")
assert(vim.fn.maparg("q", "n") ~= "" and vim.fn.maparg("]p", "n") == "", "only close is bound")

-- a stale location is reported
notes = {}
locations = { { signature = "f(x)", file = file, line = 2, source = "function f(x)" } }
definition.view(client, { "f" }, "f")
flush()
assert(noted("may be out of date"), vim.inspect(notes))

-- a grid selection afterwards takes the buffer back with its own bindings
function client:request(method, params, on_result)
	calls[#calls + 1] = { method = method, params = params }
	if method == "viewer_page" then
		on_result({ names = { "x" }, types = { "Int" }, rows = { { "1" } }, row_labels = { "1" },
			offset = 0, total_rows = 1, total_columns = 1 })
	else
		on_result({ locations = locations })
	end
end
view.open(client, { "df" })
flush()
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("df", 1, true))
assert(vim.fn.maparg("]p", "n") ~= "", "grid bindings restored")

-- without the capability, v explains instead of requesting
notes = {}
local old = { language = "julia", info = { capabilities = {} }, request = function() error("must not request") end }
definition.view(old, { "f" }, "f")
assert(noted("cannot show function definitions"), vim.inspect(notes))

-- gd: opens the file at the method's line in the editor window, not the viewer
locations = { { signature = "g(x)", file = file, line = 5, source = "g(x) = 2x" } }
vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
definition.go(client, { "g" }, "g")
flush()
assert(vim.api.nvim_get_current_win() == editor, "jumps in the editor window")
assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(file))
assert(vim.api.nvim_win_get_cursor(0)[1] == 5)

-- gd from an editor window with unsaved changes (no 'hidden') still jumps
vim.o.hidden = false
vim.cmd.enew()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
local unsaved = vim.api.nvim_get_current_buf()
editor = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
definition.go(client, { "g" }, "g")
flush()
assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(file), "no E37")
assert(vim.api.nvim_win_get_cursor(0)[1] == 5)
assert(vim.api.nvim_buf_is_valid(unsaved) and vim.bo[unsaved].modified, "unsaved buffer kept")
vim.o.hidden = true

-- several methods: the user picks one
locations = {
	{ signature = "f(x)", file = file, line = 1 },
	{ signature = "g(x)", file = file, line = 5 },
}
local offered
local select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
	offered = vim.tbl_map(opts.format_item, items)
	on_choice(items[1])
end
definition.go(client, { "f" }, "f")
flush()
vim.ui.select = select
assert(offered and #offered == 2 and offered[2]:find("g(x)", 1, true), vim.inspect(offered))
assert(vim.api.nvim_win_get_cursor(0)[1] == 1)

-- defined in the REPL: falls back to the language servers with a warning
notes = {}
locations = { { signature = "h()", file = "REPL[3]", line = 1, source = "h() = 1" } }
definition.go(client, { "h" }, "h")
flush()
assert(noted("not defined in a readable file") and noted("searching language servers"), vim.inspect(notes))
assert(noted("press v to view its source"), "no language server here: " .. vim.inspect(notes))

-- no capability: straight to the language servers
notes = {}
definition.go(old, { "h" }, "h")
flush()
assert(noted("cannot locate definitions") and not noted("press v"), vim.inspect(notes))

-- the variables pane routes v/gd for functions through definitions
local Vars = require("replconnect.vars")
local pane_client = {
	pid = 2, language = "julia", closed = false, info = { capabilities = { "definition" } },
	request = function(_, method, params, on_result)
		calls[#calls + 1] = { method = method, params = params }
		if method == "list" then
			on_result({ length = 1, version = 1, variables = { {
				access_key = "f", display_name = "f", display_value = "f (generic function with 1 method)",
				display_type = "Function", kind = "function", has_children = false,
			} } })
		else
			on_result({ locations = locations })
		end
	end,
}
local pane = Vars.init(pane_client)
pane:open()
vim.api.nvim_set_current_win(pane:winid())
for line, var in ipairs(pane.vars_flat) do
	if type(var) == "table" then vim.api.nvim_win_set_cursor(0, { line, 0 }) end
end
local before = #calls
vim.api.nvim_feedkeys("v", "x", false)
flush()
assert(calls[before + 1] and calls[before + 1].method == "definition", vim.inspect(calls[before + 1]))

os.remove(file)
os.remove(sent)
print("definition tests passed")
