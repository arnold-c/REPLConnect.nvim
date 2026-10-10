-- nvim --headless -u NONE -l tests/socket.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local uv = vim.uv
local socket = require("replconnect.socket")
local path = vim.fn.tempname() .. ".sock"
local server = uv.new_pipe(false)
assert(server:bind(path))
local peer, received = nil, ""
local function send(message)
	peer:write(vim.json.encode(message) .. "\n")
end
server:listen(8, function()
	peer = uv.new_pipe(false)
	server:accept(peer)
	peer:read_start(function(err, chunk)
		assert(not err)
		if not chunk then return end
		received = received .. chunk
		while received:find("\n", 1, true) do
			local nl = received:find("\n", 1, true)
			local req = vim.json.decode(received:sub(1, nl - 1))
			received = received:sub(nl + 1)
			if req.method == "initialize" then
				send({ jsonrpc = "2.0", id = req.id, result = { protocol_version = 1, language = "julia", pid = 1, capabilities = { "plots" } } })
			elseif req.method == "status" then
				local event = vim.json.encode({ jsonrpc = "2.0", method = "display", params = { id = 7 } }) .. "\n"
				peer:write(event:sub(1, 12))
				peer:write(event:sub(13) .. vim.json.encode({ jsonrpc = "2.0", id = req.id, result = { version = 3 } }) .. "\n")
			end
		end
	end)
end)
local client, closed
socket.connect(path, { timeout_ms = 100, on_close = function() closed = true end }, function(err, c)
	assert(not err, err); client = c
end)
assert(vim.wait(1000, function() return client ~= nil end))
local events, results, errors = 0, 0, 0
local original_notify = vim.notify
vim.notify = function() errors = errors + 1 end
client:on("display", function() error("isolated handler failure") end)
local off = client:on("display", function(record) assert(record.id == 7); events = events + 1 end)
client:request("status", {}, function(result) assert(result.version == 3); results = results + 1 end)
assert(vim.wait(1000, function() return results == 1 and events == 1 end))
assert(errors == 1)
off()
client:request("status", {}, function() results = results + 1 end)
assert(vim.wait(1000, function() return results == 2 end))
assert(events == 1)
local timed_out = 0
client:request("ignored", {}, nil, function(err) assert(err.message:find("timed out")); timed_out = timed_out + 1 end)
assert(vim.wait(1000, function() return timed_out == 1 end))
local failed = 0
local timers = {}
for _ = 1, 3 do
	local id = client:request("ignored", {}, nil, function(err)
		assert(err.message == "connection closed")
		failed = failed + 1
	end)
	timers[#timers + 1] = client.pending[id].timer
end
-- A queued notification cannot survive close.
client:_on_data('{"jsonrpc":"2.0","method":"display","params":{"id":7}}\n')
client:close()
client:close() -- idempotent; each pending request fails exactly once
assert(vim.wait(1000, function() return closed and failed == 3 end))
for _, timer in ipairs(timers) do assert(timer:is_closing()) end
assert(events == 1)
assert(next(client.handlers) == nil and next(client.pending) == nil)
vim.notify = original_notify
if peer and not peer:is_closing() then peer:close() end
server:close()
vim.fn.delete(path)
print("socket notification tests passed")
