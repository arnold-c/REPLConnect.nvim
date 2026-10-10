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
print("terminal tests passed")
