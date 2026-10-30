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

local plugin = require("replconnect")

-- A second attach to a session still connecting is ignored (it would close
-- the first mid-handshake); once that finishes, attaching works again.
local socket = require("replconnect.socket")
local original_connect, original_notify = socket.connect, vim.notify
local connects = {}
socket.connect = function(_, _, callback) connects[#connects + 1] = callback end
vim.notify = function() end
local session = { pid = 1, socket = "/tmp/replconnect-test.sock" }
plugin.attach(session)
plugin.attach(session)
assert(#connects == 1, "duplicate attach while connecting is ignored")
connects[1]("connect failed: test")
plugin.attach(session)
assert(#connects == 2, "attach works again after the first finished")
connects[2]("connect failed: test")
socket.connect, vim.notify = original_connect, original_notify

-- :REPLAttach only attaches without asking to the one session in the cwd.
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

-- auto_attach never opens the picker: only the one session in the cwd.
local function auto(sessions)
	attached, offered = nil, nil
	discover.list = function() return sessions end
	return plugin.auto_attach()
end
assert(not auto({ there }) and not attached and not offered, "elsewhere: nothing happens")
assert(not auto({}) and not attached and not offered)
assert(not auto({ here, { pid = 3, cwd = cwd } }) and not attached and not offered)
assert(auto({ there, here }) and attached == here)

discover.list, plugin.attach, picker.select = original_list, original_attach, original_select

print("picker: ok")
