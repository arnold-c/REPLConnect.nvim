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
