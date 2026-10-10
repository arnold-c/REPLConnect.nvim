-- nvim --headless -u NONE -l tests/plots_toggle.lua
-- Plot capture enabled/disabled at runtime reaches an attached editor.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local uv = vim.uv
local plugin = require("replconnect")
plugin.setup({ completion = false, plots = { renderer = "external" } })
local path = vim.fn.tempname() .. ".sock"
local server = uv.new_pipe(false)
assert(server:bind(path))
local peer, requests = nil, {}
local function send(message) peer:write(vim.json.encode(message) .. "\n") end
server:listen(8, function()
	peer = uv.new_pipe(false)
	server:accept(peer)
	local buffer = ""
	peer:read_start(function(err, chunk)
		assert(not err)
		if not chunk then return end
		buffer = buffer .. chunk
		while buffer:find("\n", 1, true) do
			local nl = buffer:find("\n", 1, true)
			local req = vim.json.decode(buffer:sub(1, nl - 1))
			buffer = buffer:sub(nl + 1)
			requests[#requests + 1] = req.method
			local result = req.method == "initialize"
					and { protocol_version = 1, language = "julia", language_version = "1.13", pid = 1, capabilities = { "variables" } }
				or { plots = {} }
			send({ jsonrpc = "2.0", id = req.id, result = result })
		end
	end)
end)
local messages = {}
local original_notify = vim.notify
vim.notify = function(message) messages[#messages + 1] = message end
local function last_message() return messages[#messages] or "" end
local function capabilities(list) send({ jsonrpc = "2.0", method = "capabilities", params = { capabilities = list } }) end

plugin.attach({ pid = 1, socket = path })
assert(vim.wait(2000, function() return plugin.client() ~= nil end))
plugin.open_plots()
assert(last_message():find("plots unavailable", 1, true), last_message())

-- Enabled later: the attached editor creates a pane and subscribes.
capabilities({ "variables", "plots" })
assert(vim.wait(2000, function() return vim.tbl_contains(requests, "plots_subscribe") end))
assert(last_message():find("plot capture enabled", 1, true), last_message())
plugin.open_plots()
local pane_buf = vim.fn.bufnr("replconnect://plots/julia")
assert(pane_buf > 0 and vim.fn.bufwinid(pane_buf) ~= -1, "pane must open after capture is enabled")

-- Disabled: the pane and its subscription are removed.
capabilities({ "variables" })
assert(vim.wait(2000, function() return last_message():find("plot capture disabled", 1, true) ~= nil end))
assert(vim.fn.bufnr("replconnect://plots/julia") == -1, "pane must be wiped after capture is disabled")
plugin.open_plots()
assert(last_message():find("plots unavailable", 1, true), last_message())

-- Unchanged capabilities do not recreate anything.
local count = #messages
capabilities({ "variables", "history" })
vim.wait(100)
assert(#messages == count and plugin.client().info.capabilities[2] == "history")

vim.notify = original_notify
plugin.detach()
peer:close()
server:close()
vim.fn.delete(path)
print("plot capture toggle tests passed")
