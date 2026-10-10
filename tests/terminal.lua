-- Run from the repository root: nvim --headless -u NONE -l tests/terminal.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local terminal = require("replconnect.terminal")
local discover = require("replconnect.discover")

local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end

-- ancestors: nearest first, includes the pid itself, stops at init / on failure
local parents = { [400] = 300, [300] = 200, [200] = 1 }
eq(terminal.ancestors(400, function(p) return parents[p] end), { 400, 300, 200 })
eq(terminal.ancestors(999, function() return nil end), { 999 })
eq(terminal.ancestors(1, function() return nil end), {})
-- a cycle cannot loop forever
assert(#terminal.ancestors(5, function() return 5 end) <= 32)

-- the host is the terminal whose job is an ancestor
eq(terminal.find_host({ 400, 300, 200 }, { [7] = 300, [8] = 555 }), 7)
eq(terminal.find_host({ 400, 300, 200 }, { [8] = 555 }), nil)
eq(terminal.find_host({ 400 }, {}), nil)

-- real processes: ps works and Neovim's own parent is found
local parent = terminal.parent_pid(vim.fn.getpid())
assert(type(parent) == "number" and parent >= 1, "ps lookup failed: " .. vim.inspect(parent))
local chain = terminal.ancestors(vim.fn.getpid())
assert(chain[1] == vim.fn.getpid() and #chain >= 1)

-- a real :terminal buffer is recognised through its job pid
vim.cmd("terminal sleep 5")
local bufnr = vim.api.nvim_get_current_buf()
assert(vim.wait(2000, function() return type(vim.b[bufnr].terminal_job_pid) == "number" end))
local job = vim.b[bufnr].terminal_job_pid
eq(terminal.terminal_jobs()[bufnr], job)
eq(terminal.host_buffer(job), bufnr) -- the job itself counts
assert(terminal.host_buffer(vim.fn.getpid()) == nil, "Neovim itself is not inside its own terminal")

-- the picker puts sessions in a Neovim terminal first, then same cwd, then newest
local sessions = {
	{ pid = 1, cwd = "/other", started_at = 300 },
	{ pid = 2, cwd = "/here", started_at = 100 },
	{ pid = 3, cwd = "/other", started_at = 200, terminal_buf = 9 },
	{ pid = 4, cwd = "/here", started_at = 400 },
}
local order = vim.tbl_map(function(s) return s.pid end, discover.sort(sessions, "/here"))
eq(order, { 3, 4, 2, 1 })
assert(discover.label({ pid = 3, cwd = "/x", project = "", terminal_buf = 9 }):find("nvim terminal", 1, true))
assert(not discover.label({ pid = 3, cwd = "/x", project = "" }):find("nvim terminal", 1, true))

vim.api.nvim_buf_delete(bufnr, { force = true })
-- origin: where a session runs relative to this Neovim (pid 50 here)
local tree = { [400] = 300, [300] = 50, [500] = 60, [60] = 2, [700] = 1, [800] = 70, [70] = 2 }
local names = { [50] = "nvim", [60] = "nvim", [70] = "zsh", [300] = "node" }
local function origin(pid, extra)
	return terminal.origin(pid, vim.tbl_extend("force", {
		self_pid = 50,
		parent = function(p) return tree[p] end,
		name = function(p) return names[p] end,
	}, extra or {}))
end
eq(origin(400, { launched = { [400] = true } }), "started by this Neovim")
eq(origin(400, { terminal_buf = 3 }), "in a terminal of this Neovim")
eq(origin(400), "child of this Neovim, not a terminal") -- e.g. a language server
eq(origin(500), "in another Neovim (pid 60)")
eq(origin(700), "orphaned (its parent exited)")
eq(origin(800), "external")

-- labels show the origin when given, else whether it is in one of our terminals
local info = { pid = 9, cwd = "/tmp", language = "julia" }
-- right after the language
assert(discover.label(info, "external"):find("^julia \u{b7} external \u{b7} /tmp "), discover.label(info, "external"))
assert(not discover.label(info):find("nvim terminal", 1, true))
info.terminal_buf = 1
assert(discover.label(info):find("^julia \u{b7} nvim terminal \u{b7} "), discover.label(info))

print("terminal tests passed")
