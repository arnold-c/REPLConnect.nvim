-- Find running REPLConnect sessions through their discovery files
-- (`<dir>/<pid>.json`, see docs/protocol.md).

local uv = vim.uv or vim.loop

local M = {}

---Directories to search (mirrors `socket_dir()` in Julia): `$REPLCONNECT_DIR`
---if set, else `/tmp/replconnect-<uid>`. TMPDIR/XDG_RUNTIME_DIR are ignored on
---purpose: the editor and the REPL often do not share them.
---@param env? table<string, string|nil>
function M.dirs(env)
	env = env or { REPLCONNECT_DIR = vim.env.REPLCONNECT_DIR }
	local custom = env.REPLCONNECT_DIR
	if custom and custom ~= "" then
		return { custom }
	end
	return { "/tmp/replconnect-" .. tostring(uv.getuid()) }
end

---Whether process `pid` is running.
---@param pid integer
---@return boolean
function M.pid_alive(pid)
	-- uv.kill returns 0 on success and nil, err on failure (it does not throw).
	local ok, res = pcall(uv.kill, pid, 0)
	return ok and res == 0
end
local pid_alive = M.pid_alive

local function read_json(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local ok, value = pcall(vim.json.decode, text)
	return ok and type(value) == "table" and value or nil
end

---Whether `info` describes a live session: pid running and socket present.
function M.is_live(info)
	return type(info.pid) == "number"
		and type(info.socket) == "string"
		and pid_alive(info.pid)
		and uv.fs_stat(info.socket) ~= nil
end

---Order for the picker: sessions running in a Neovim terminal (`terminal_buf`)
---first, then those whose cwd is Neovim's, then the most recently started.
function M.sort(sessions, cwd)
	table.sort(sessions, function(a, b)
		local a_term, b_term = a.terminal_buf ~= nil, b.terminal_buf ~= nil
		if a_term ~= b_term then
			return a_term
		end
		local a_here, b_here = a.cwd == cwd, b.cwd == cwd
		if a_here ~= b_here then
			return a_here
		end
		return (a.started_at or 0) > (b.started_at or 0)
	end)
	return sessions
end

---List live sessions. Discovery files of dead sessions are skipped.
---@param opts? { dirs?: string[], cwd?: string }
---@return table[] sessions discovery records
function M.list(opts)
	opts = opts or {}
	local sessions, seen = {}, {}
	for _, dir in ipairs(opts.dirs or M.dirs()) do
		for _, name in ipairs(vim.fn.glob(vim.fs.joinpath(dir, "*.json"), false, true)) do
			local info = read_json(name)
			if info and not seen[info.socket] and M.is_live(info) then
				seen[info.socket] = true
				info.terminal_buf = require("replconnect.terminal").host_buffer(info.pid)
				sessions[#sessions + 1] = info
			end
		end
	end
	return M.sort(sessions, opts.cwd or vim.fn.getcwd())
end

---The session's language; discovery files of older services have none (Julia).
---@param info table discovery record
---@return string
function M.language(info)
	return type(info.language) == "string" and info.language or "julia"
end

---One-line description for a picker.
function M.label(info)
	local started = info.started_at and os.date("%H:%M:%S", info.started_at) or "?"
	local project = (info.project or "") ~= "" and vim.fn.fnamemodify(info.project, ":h:t") or "-"
	local where = info.terminal_buf and " · nvim terminal" or ""
	return ("%s · %s · %s · pid %d · %s%s"):format(
		require("replconnect.languages").label(M.language(info)),
		vim.fn.fnamemodify(info.cwd or "", ":~"),
		project,
		info.pid,
		started,
		where
	)
end

return M
