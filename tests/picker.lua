-- Run from the repository root: nvim --headless -u NONE -l tests/picker.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local picker = require("replconnect.picker")

assert(picker.transcript({})[1] == "# no evaluations yet")

local lines = picker.transcript({
	{ input = "x = 1 + 1" },
	{ input = "begin\n    f()\nend" },
}, "julia> ")
assert(vim.deep_equal(lines, {
	"julia> x = 1 + 1",
	"julia> begin",
	"           f()",
	"       end",
}), vim.inspect(lines))

-- A default prompt is neutral; languages supply their own.
assert(picker.transcript({ { input = "a" } })[1] == "> a")

-- R sessions preview with their own prompt.
local r_lines = picker.transcript({ { input = "x <- 1" }, { input = "f(\n  x\n)" } }, "> ")
assert(vim.deep_equal(r_lines, { "> x <- 1", "> f(", "    x", "  )" }), vim.inspect(r_lines))

print("picker: ok")
