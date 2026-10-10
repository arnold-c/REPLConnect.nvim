-- nvim --headless -u NONE -l tests/socket_ready.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local uv = vim.uv
local socket = require("replconnect.socket")
local path = vim.fn.tempname() .. ".sock"
local server = uv.new_pipe(false)
assert(server:bind(path))
local peers, requests, mode = {}, 0, "late"
server:listen(8, function()
	local peer = uv.new_pipe(false)
	server:accept(peer)
	peers[#peers + 1] = peer
	local buffer, count = "", 0
	local connection_mode = mode
	peer:read_start(function(err, chunk)
		assert(not err)
		if not chunk then return end
		buffer = buffer .. chunk
		while buffer:find("\n", 1, true) do
			local nl = buffer:find("\n", 1, true)
			local req = vim.json.decode(buffer:sub(1, nl - 1))
			buffer = buffer:sub(nl + 1)
			assert(req.method == "initialize")
			count, requests = count + 1, requests + 1
			local capabilities = { "complete" }
			if connection_mode == "late" and count >= 3 then capabilities[#capabilities + 1] = "plots" end
			peer:write(vim.json.encode({ jsonrpc = "2.0", id = req.id, result = {
				protocol_version = 1, language = "julia", pid = 1, capabilities = capabilities,
			} }) .. "\n")
		end
	end)
end)
-- Discovery/initialize can happen before the launch hook enables capture.
local client, calls = nil, 0
socket.connect(path, { required_capabilities = { "plots" }, ready_timeout_ms = 2000 }, function(err, c)
	assert(not err, err)
	calls = calls + 1
	client = c
end)
assert(vim.wait(1000, function() return requests >= 1 end))
assert(not client, "must not attach using the incomplete capability snapshot")
assert(vim.wait(3000, function() return client ~= nil end))
assert(calls == 1 and vim.tbl_contains(client.info.capabilities, "plots"))
client:close()
-- Ordinary attachments to legacy services do not require plots or retry.
mode = "never"
local legacy
local before = requests
socket.connect(path, {}, function(err, c) assert(not err, err); legacy = c end)
assert(vim.wait(1000, function() return legacy ~= nil end))
assert(requests == before + 1)
legacy:close()
-- Missing requested capabilities fail explicitly rather than attaching silently.
local failure, failures = nil, 0
socket.connect(path, { required_capabilities = { "plots" }, ready_timeout_ms = 150 }, function(err, c)
	assert(not c)
	failure, failures = err, failures + 1
end)
assert(vim.wait(2000, function() return failure ~= nil end))
assert(failures == 1 and failure:find("requested capabilities: plots", 1, true))
-- Disconnect while waiting between initialize retries still settles the handshake.
local disconnected
before = requests
socket.connect(path, { required_capabilities = { "plots" }, ready_timeout_ms = 2000 }, function(err, c)
	assert(not c)
	disconnected = err
end)
assert(vim.wait(1000, function() return requests > before end))
peers[#peers]:close()
assert(vim.wait(2000, function() return disconnected ~= nil end))
for _, peer in ipairs(peers) do if not peer:is_closing() then peer:close() end end
server:close()
vim.fn.delete(path)
print("socket startup readiness tests passed")
