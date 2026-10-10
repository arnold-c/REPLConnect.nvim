-- nvim --headless -u NONE -l tests/restart.lua
-- A REPL in a Neovim terminal that restarts in place (arf's :restart keeps
-- the pid) is reattached once its new server is up; a REPL whose terminal job
-- ended is reported as disconnected.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local uv = vim.uv
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end
local plugin = require("replconnect")
local repl = require("replconnect.repl")
local discover = require("replconnect.discover")
local terminal = require("replconnect.terminal")
plugin.setup({ completion = false })
repl.POLL_MS = 10
plugin.RESTART_GRACE_MS = 20

---A fake service generation; `close()` drops its connections like an exec.
local function generation(started_at)
	local path = vim.fn.tempname() .. ".sock"
	local server = uv.new_pipe(false)
	local peers = {}
	assert(server:bind(path))
	server:listen(8, function()
		local peer = uv.new_pipe(false)
		server:accept(peer)
		peers[#peers + 1] = peer
		local buffer = ""
		peer:read_start(function(err, chunk)
			if err or not chunk then return end
			buffer = buffer .. chunk
			while buffer:find("\n", 1, true) do
				local nl = buffer:find("\n", 1, true)
				local req = vim.json.decode(buffer:sub(1, nl - 1))
				buffer = buffer:sub(nl + 1)
				local result = req.method == "initialize"
						and { protocol_version = 1, language = "r", language_version = "4.4", pid = 7,
							started_at = started_at, capabilities = { "variables" } }
					or vim.empty_dict()
				peer:write(vim.json.encode({ jsonrpc = "2.0", id = req.id, result = result }) .. "\n")
			end
		end)
	end)
	return {
		info = { pid = 7, socket = path, language = "r", started_at = started_at },
		close = function()
			for _, peer in ipairs(peers) do
				if not peer:is_closing() then peer:close() end
			end
			server:close()
			vim.fn.delete(path)
		end,
	}
end

local messages = {}
local original_notify = vim.notify
vim.notify = function(message) messages[#messages + 1] = message end
local function saw(text)
	for _, message in ipairs(messages) do
		if message:find(text, 1, true) then return true end
	end
	return false
end

-- The REPL runs in a terminal (a long-running job stands in for arf).
local term_buf = vim.api.nvim_create_buf(false, true)
local job = vim.api.nvim_buf_call(term_buf, function() return vim.fn.jobstart({ "sleep", "60" }, { term = true }) end)
assert(job > 0)
local original_host, original_list = terminal.host_buffer, discover.list
terminal.host_buffer = function() return term_buf end
local records = {}
discover.list = function() return records end

local first = generation(100)
records = { vim.tbl_extend("force", first.info, { terminal_buf = term_buf }) }
plugin.attach(first.info)
assert(vim.wait(2000, function() return plugin.client("r") ~= nil end))

-- Restart in place: the old server goes away, its record lingers for a while.
first.close()
assert(vim.wait(2000, function() return saw("reconnecting when it restarts") end), vim.inspect(messages))
assert(not saw("disconnected; :REPLAttach to reconnect"))
eq(plugin.client("r"), nil)
vim.wait(100)
eq(plugin.client("r"), nil) -- the stale record (same pid, old started_at) is ignored

local second = generation(200)
records = { vim.tbl_extend("force", second.info, { terminal_buf = term_buf }) }
assert(vim.wait(2000, function() return plugin.client("r") ~= nil end))
eq(plugin.client("r").info.started_at, 200)

-- The REPL exits: its job ends and the session is reported as disconnected.
messages = {}
vim.fn.jobstop(job)
assert(vim.fn.jobwait({ job }, 1000)[1] ~= -1)
second.close()
assert(vim.wait(2000, function() return saw("r session disconnected; :REPLAttach to reconnect") end),
	vim.inspect(messages))
assert(not saw("reconnecting"))

-- Not in a Neovim terminal: no reconnect either.
terminal.host_buffer = function() return nil end
local third = generation(300)
plugin.attach(third.info)
assert(vim.wait(2000, function() return plugin.client("r") ~= nil end))
messages = {}
third.close()
assert(vim.wait(2000, function() return saw(":REPLAttach to reconnect") end), vim.inspect(messages))
assert(not saw("reconnecting"))

terminal.host_buffer, discover.list = original_host, original_list
vim.notify = original_notify
print("restart tests passed")
