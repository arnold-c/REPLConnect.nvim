-- Finding the REPL inside a Neovim `:terminal`.
--
-- When the REPL runs in a Neovim terminal buffer, leaving that buffer is the
-- moment its variables may have changed and the user is looking at the pane.
-- The REPL process is a descendant of the terminal's job (shell -> julia), so
-- it is found by walking parent pids. This is optional: nothing else depends
-- on it, and REPLs in other terminals are synced by focus events instead.

local M = {}

local MAX_DEPTH = 32

---Parent pid of `pid` (via `ps`, which works on Linux and macOS), or nil.
---@param pid integer
---@return integer?
function M.parent_pid(pid)
	local ok, result = pcall(function()
		return vim.system({ "ps", "-o", "ppid=", "-p", tostring(pid) }, { text = true }):wait()
	end)
	if not ok or result.code ~= 0 then
		return nil
	end
	return tonumber(vim.trim(result.stdout or ""))
end

---Executable name of `pid` (basename, via `ps`), or nil.
---@param pid integer
---@return string?
function M.process_name(pid)
	local ok, result = pcall(function()
		return vim.system({ "ps", "-o", "comm=", "-p", tostring(pid) }, { text = true }):wait()
	end)
	if not ok or result.code ~= 0 then
		return nil
	end
	local name = vim.trim(result.stdout or "")
	return name ~= "" and vim.fs.basename(name) or nil
end

---@class replconnect.OriginOptions
---@field launched? table<integer, boolean> pids this Neovim started with :REPLStart
---@field terminal_buf? integer this Neovim's terminal buffer running the process
---@field self_pid? integer default: this Neovim's pid
---@field parent? fun(pid: integer): integer? replaceable for tests
---@field name? fun(pid: integer): string? replaceable for tests

---Where process `pid` runs relative to this Neovim, for pickers: started here,
---in a terminal here, a non-terminal child here (e.g. a language server), in
---another Neovim, orphaned (its parent exited), or external.
---@param pid integer
---@param opts? replconnect.OriginOptions
---@return string
function M.origin(pid, opts)
	opts = opts or {}
	local parent, name = opts.parent or M.parent_pid, opts.name or M.process_name
	local self_pid = opts.self_pid or vim.fn.getpid()
	if opts.launched and opts.launched[pid] then
		return "started by this Neovim"
	end
	if opts.terminal_buf then
		return "in a terminal of this Neovim"
	end
	local chain = M.ancestors(pid, parent)
	if #chain == 1 and parent(pid) == 1 then
		return "orphaned (its parent exited)"
	end
	for i = 2, #chain do
		if chain[i] == self_pid then
			return "child of this Neovim, not a terminal"
		end
		if name(chain[i]) == "nvim" then
			return ("in another Neovim (pid %d)"):format(chain[i])
		end
	end
	return "external"
end

---`pid` followed by its ancestors, nearest first (stops at pid 1 or on lookup failure).
---@param pid integer
---@param parent? fun(pid: integer): integer? Replaceable for tests.
---@return integer[]
function M.ancestors(pid, parent)
	parent = parent or M.parent_pid
	local out = {}
	while pid and pid > 1 and #out < MAX_DEPTH do
		out[#out + 1] = pid
		pid = parent(pid)
	end
	return out
end

---Terminal buffers and the pid of their job.
---@return table<integer, integer> bufnr -> job pid
function M.terminal_jobs()
	local jobs = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "terminal" then
			local job = vim.b[bufnr].terminal_job_pid
			if type(job) == "number" then
				jobs[bufnr] = job
			end
		end
	end
	return jobs
end

---The terminal buffer whose job is an ancestor of the process, or nil.
---@param ancestor_pids integer[] from `ancestors`
---@param jobs table<integer, integer> from `terminal_jobs`
---@return integer?
function M.find_host(ancestor_pids, jobs)
	local lookup = {}
	for _, pid in ipairs(ancestor_pids) do
		lookup[pid] = true
	end
	for bufnr, job in pairs(jobs) do
		if lookup[job] then
			return bufnr
		end
	end
end

---The Neovim terminal buffer running the process `pid`, or nil if it runs elsewhere.
---@param pid integer
---@return integer?
function M.host_buffer(pid)
	local jobs = M.terminal_jobs()
	if next(jobs) == nil then
		return nil -- no terminals: skip the process lookups
	end
	return M.find_host(M.ancestors(pid), jobs)
end

return M
