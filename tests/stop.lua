-- nvim --headless -u NONE -l tests/stop.lua
-- :REPLStop shuts down the attached server; ! also closes its terminal REPL.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local uv = vim.uv
local plugin = require("replconnect")
dofile("tests/support/fake_languages.lua")()
local terminal = require("replconnect.terminal")
plugin.setup({ completion = false })
local path = vim.fn.tempname() .. ".sock"
local server = uv.new_pipe(false)
assert(server:bind(path))
local capabilities, requests = { "variables", "shutdown" }, {}
server:listen(8, function()
	local peer = uv.new_pipe(false)
	server:accept(peer)
	local buffer = ""
	peer:read_start(function(err, chunk)
		if err or not chunk then return end
		buffer = buffer .. chunk
		while buffer:find("\n", 1, true) do
			local nl = buffer:find("\n", 1, true)
			local req = vim.json.decode(buffer:sub(1, nl - 1))
			buffer = buffer:sub(nl + 1)
			requests[#requests + 1] = req.method
			local result = req.method == "initialize"
					and { protocol_version = 1, language = "julia", language_version = "1.13", pid = 1, capabilities = capabilities }
				or vim.empty_dict()
			peer:write(vim.json.encode({ jsonrpc = "2.0", id = req.id, result = result }) .. "\n")
			if req.method == "shutdown" then peer:close() end -- like stop(): connection goes away
		end
	end)
end)
local messages = {}
local original_notify = vim.notify
vim.notify = function(message) messages[#messages + 1] = message end
local function saw(text)
	for _, message in ipairs(messages) do
		if message:find(text, 1, true) then return true end
	end
	return false
end
local function attach()
	plugin.attach({ pid = 1, socket = path })
	assert(vim.wait(2000, function() return plugin.client() ~= nil end))
end

-- Services without the capability are not asked.
capabilities = { "variables" }
attach()
plugin.stop()
assert(saw("cannot be stopped from Neovim"))
assert(plugin.client() ~= nil and not vim.tbl_contains(requests, "shutdown"))
plugin.detach()

-- Stop the server; the REPL (not in a Neovim terminal) keeps running.
capabilities = { "variables", "shutdown" }
attach()
plugin.stop(nil, true)
assert(vim.wait(2000, function() return saw("stopped the REPLConnect server (pid 1)") end))
assert(saw("not in a Neovim terminal"))
assert(plugin.client() == nil)
vim.wait(100)
assert(not saw("disconnected"), "an intended stop is not reported as a lost session")

-- With !, a hidden terminal REPL is closed as well.
local term_buf = vim.api.nvim_create_buf(false, true)
local job = vim.api.nvim_buf_call(term_buf, function() return vim.fn.jobstart({ "sleep", "60" }, { term = true }) end)
assert(job > 0)
local original_host = terminal.host_buffer
terminal.host_buffer = function() return term_buf end
attach()
terminal.host_buffer = original_host
plugin.stop(nil, true)
assert(vim.wait(2000, function() return saw("stopped and closed the Julia REPL (pid 1)") end))
assert(not vim.api.nvim_buf_is_valid(term_buf))
assert(vim.fn.jobwait({ job }, 1000)[1] ~= -1, "the terminal job must end")

-- Not attached: the usual hint.
plugin.stop()
assert(saw("not attached; run :REPLAttach"))

vim.notify = original_notify
server:close()
vim.fn.delete(path)
print("stop tests passed")
