-- nvim --headless -u NONE -l tests/stop.lua
-- :REPLStop picks any discovered session (attached first), asks for
-- confirmation and shuts its server down; ! also closes its terminal REPL.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local uv = vim.uv
local plugin = require("replconnect")
dofile("tests/support/fake_languages.lua")()
local terminal = require("replconnect.terminal")
local picker = require("replconnect.picker")
plugin.setup({ completion = false })

local pid = vim.fn.getpid() -- discovery only lists live pids
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.env.REPLCONNECT_DIR = dir

---A fake service; returns its socket path and the methods it was asked.
local function serve(name, capabilities)
	local path = vim.fs.joinpath(dir, name .. ".sock")
	local requests = {}
	local server = uv.new_pipe(false)
	assert(server:bind(path))
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
						and { protocol_version = 1, language = "julia", language_version = "1.13", pid = pid,
							capabilities = capabilities.list }
					or vim.empty_dict()
				peer:write(vim.json.encode({ jsonrpc = "2.0", id = req.id, result = result }) .. "\n")
				if req.method == "shutdown" then peer:close() end -- like stop(): connection goes away
			end
		end)
	end)
	return path, requests, server
end

---Publish (or remove, with nil) the discovery file of the session at `path`.
local discovery = vim.fs.joinpath(dir, pid .. ".json")
local function publish(path)
	vim.fn.delete(discovery)
	if path then
		vim.fn.writefile({ vim.json.encode({ pid = pid, socket = path, language = "julia", started_at = os.time() }) },
			discovery)
	end
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

-- Pick the first offered session (or `pick_all`); record what was offered and asked.
local offered, titles, questions, answer, pick_all = {}, {}, {}, 1, false
picker.select = function(sessions, on_choice, opts)
	assert(opts.multi, ":REPLStop allows selecting several sessions")
	offered = vim.tbl_map(opts.format_item, sessions)
	titles[#titles + 1] = opts.title
	on_choice(pick_all and sessions or { sessions[1] })
end
vim.fn.confirm = function(question)
	questions[#questions + 1] = question
	return answer
end

local caps = { list = { "variables", "shutdown" } }
local path, requests = serve("a", caps)
publish(path)
local function attach()
	plugin.attach({ pid = pid, socket = path })
	assert(vim.wait(2000, function() return plugin.client() ~= nil end))
end

-- Even a single session is picked and confirmed; declining stops nothing.
attach()
answer = 2
plugin.stop()
assert(#titles == 1 and titles[1] == "Stop REPL", vim.inspect(titles))
assert(offered[1]:find("· attached", 1, true), vim.inspect(offered))
assert(#questions == 1 and questions[1]:find("pid " .. pid, 1, true), vim.inspect(questions))
assert(plugin.client() ~= nil and not vim.tbl_contains(requests, "shutdown"))
answer = 1

-- Services without the capability are not asked.
plugin.detach()
caps.list = { "variables" }
attach()
plugin.stop()
assert(saw("cannot be stopped from Neovim"))
assert(plugin.client() ~= nil and not vim.tbl_contains(requests, "shutdown"))
plugin.detach()

-- Stop the attached server; the REPL (not in a Neovim terminal) keeps running.
caps.list = { "variables", "shutdown" }
attach()
plugin.stop(nil, true)
assert(titles[#titles] == "Stop and close REPL")
assert(vim.wait(2000, function() return saw(("stopped the REPLConnect server (pid %d)"):format(pid)) end))
assert(saw("not in a Neovim terminal"))
assert(plugin.client() == nil)
vim.wait(100)
assert(not saw("disconnected"), "an intended stop is not reported as a lost session")

-- An unattached session is stopped over its own connection.
messages = {}
local path_b, requests_b = serve("b", { list = { "variables", "shutdown" } })
publish(path_b)
plugin.stop()
assert(not offered[1]:find("attached", 1, true), vim.inspect(offered))
assert(vim.wait(2000, function() return saw("stopped the REPLConnect server") end))
assert(vim.tbl_contains(requests_b, "shutdown"))
assert(plugin.client() == nil)

-- With !, a hidden terminal REPL is closed as well.
local path_c = serve("c", { list = { "variables", "shutdown" } })
publish(path_c)
path = path_c
local term_buf = vim.api.nvim_create_buf(false, true)
local job = vim.api.nvim_buf_call(term_buf, function() return vim.fn.jobstart({ "sleep", "60" }, { term = true }) end)
assert(job > 0)
local original_host = terminal.host_buffer
terminal.host_buffer = function() return term_buf end
attach()
plugin.stop(nil, true)
terminal.host_buffer = original_host
assert(questions[#questions]:find("stop and close", 1, true), vim.inspect(questions))
assert(vim.wait(2000, function() return saw("stopped and closed the Julia REPL") end))
assert(not vim.api.nvim_buf_is_valid(term_buf))
assert(vim.fn.jobwait({ job }, 1000)[1] ~= -1, "the terminal job must end")

-- Several selected sessions are confirmed once and all stopped.
publish(nil)
local path_d, requests_d = serve("d", { list = { "variables", "shutdown" } })
local path_e, requests_e = serve("e", { list = { "variables", "shutdown" } })
for name, p in pairs({ d = path_d, e = path_e }) do
	vim.fn.writefile({ vim.json.encode({ pid = pid, socket = p, language = "julia", started_at = os.time() }) },
		vim.fs.joinpath(dir, name .. ".json"))
end
local asked = #questions
pick_all = true
plugin.stop()
pick_all = false
assert(#questions == asked + 1 and questions[#questions]:find("Stop these 2 REPLs?", 1, true),
	vim.inspect(questions))
assert(vim.wait(2000, function()
	return vim.tbl_contains(requests_d, "shutdown") and vim.tbl_contains(requests_e, "shutdown")
end))
vim.fn.delete(vim.fs.joinpath(dir, "d.json"))
vim.fn.delete(vim.fs.joinpath(dir, "e.json"))

-- A session whose socket accepts but never answers (orphaned REPL) can be killed.
local orphan = vim.fn.jobstart({ "sleep", "60" })
local orphan_pid = vim.fn.jobpid(orphan)
local silent_path = vim.fs.joinpath(dir, "silent.sock")
local silent = uv.new_pipe(false)
assert(silent:bind(silent_path))
silent:listen(8, function()
	local peer = uv.new_pipe(false)
	silent:accept(peer)
	peer:read_start(function() end) -- never replies
end)
publish(nil)
vim.fn.writefile({ vim.json.encode({ pid = orphan_pid, socket = silent_path, language = "julia" }) },
	vim.fs.joinpath(dir, "silent.json"))
plugin.KILL_GRACE_MS = 100
messages, asked = {}, #questions
plugin.stop(orphan_pid)
assert(vim.wait(5000, function() return #questions == asked + 2 end), vim.inspect(questions))
assert(questions[#questions]:find("is not responding", 1, true), vim.inspect(questions))
assert(vim.wait(2000, function() return saw(("killed the Julia REPL (pid %d"):format(orphan_pid)) end),
	vim.inspect(messages))
assert(vim.fn.jobwait({ orphan }, 1000)[1] ~= -1, "the orphaned process must end")
silent:close()
vim.fn.delete(vim.fs.joinpath(dir, "silent.json"))

-- Filters: another language or pid offers nothing.
publish(path_c)
messages = {}
plugin.stop("r")
assert(saw("no running REPL found"))
messages = {}
plugin.stop(pid + 1)
assert(saw("no running REPL found"))

vim.notify = original_notify
vim.fn.delete(dir, "rf")
print("stop tests passed")
