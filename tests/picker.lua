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

-- Sessions match Neovim's working directory after normalisation.
local discover = require("replconnect.discover")
local cwd = vim.fn.getcwd()
assert(discover.in_dir({ cwd = cwd .. "/" }, cwd))
assert(not discover.in_dir({ cwd = "/elsewhere" }, cwd))
assert(not discover.in_dir({}, cwd))

-- :REPLAttach only attaches without asking to the one session in the cwd.
local plugin = require("replconnect")
local original_list, original_attach, original_select = discover.list, plugin.attach, picker.select
local attached, offered
plugin.attach = function(info) attached = info end
picker.select = function(sessions) offered = sessions end
local function pick(sessions, pid)
	attached, offered = nil, nil
	discover.list = function() return sessions end
	plugin.pick(pid)
end

local here = { pid = 1, cwd = cwd }
local there = { pid = 2, cwd = "/elsewhere" }
pick({ there })
assert(not attached and offered and #offered == 1, "a session elsewhere is offered, not attached")
pick({ here })
assert(attached == here and not offered)
pick({ there, here })
assert(attached == here and not offered, "the one session in the cwd wins")
pick({ here, { pid = 3, cwd = cwd } })
assert(not attached and #offered == 2, "several sessions in the cwd are offered")
pick({ there }, 2)
assert(attached == there, "an explicit pid attaches anywhere")

discover.list, plugin.attach, picker.select = original_list, original_attach, original_select

print("picker: ok")
