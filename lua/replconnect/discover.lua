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

---Command line of process `pid` (via `ps`), or nil when unavailable.
---@param pid integer
---@return string?
function M.command(pid)
	local ok, result = pcall(function()
		return vim.system({ "ps", "-ww", "-o", "command=", "-p", tostring(pid) }, { text = true }):wait(1000)
	end)
	local command = ok and result.code == 0 and vim.trim(result.stdout or "") or ""
	return command ~= "" and command or nil
end

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

---`path` resolved (symlinks, `~`, trailing slashes) for comparison.
---@param path string
---@return string
local function canonical(path)
	local normalized = vim.fs.normalize(path)
	return uv.fs_realpath(normalized) or normalized
end

---Whether the session `info` runs in directory `cwd` (default: Neovim's).
---@param info table discovery record
---@param cwd? string
---@return boolean
function M.in_dir(info, cwd)
	return type(info.cwd) == "string" and info.cwd ~= ""
		and canonical(info.cwd) == canonical(cwd or vim.fn.getcwd())
end

---Sort key of `info` for the picker; compared element by element.
---@param info table discovery record
---@param cwd string
---@return (integer|string)[]
local function sort_key(info, cwd)
	local has_dir = type(info.cwd) == "string" and info.cwd ~= ""
	return {
		M.in_dir(info, cwd) and 0 or has_dir and 1 or 2,
		has_dir and canonical(info.cwd) or "",
		info.terminal_buf ~= nil and 0 or 1,
		-(info.started_at or 0),
	}
end

---Order for the picker, grouped by working directory: Neovim's first, then the
---others alphabetically (sessions without one last). Within a group, sessions
---in a Neovim terminal (`terminal_buf`) come first, then the most recent.
function M.sort(sessions, cwd)
	local keys = {}
	for _, info in ipairs(sessions) do
		keys[info] = sort_key(info, cwd)
	end
	table.sort(sessions, function(a, b)
		local ka, kb = keys[a], keys[b]
		for i = 1, #ka do
			if ka[i] ~= kb[i] then
				return ka[i] < kb[i]
			end
		end
		return false
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
---@param info table discovery record
---@param where? string where it runs (default: "nvim terminal" when in one of ours)
function M.label(info, where)
	local started = info.started_at and os.date("%H:%M:%S", info.started_at) or "?"
	local project = (info.project or "") ~= "" and vim.fn.fnamemodify(info.project, ":h:t") or "-"
	where = where or (info.terminal_buf and "nvim terminal")
	where = where and (" · " .. where) or ""
	return ("%s%s · %s · %s · pid %d · %s"):format(
		require("replconnect.languages").label(M.language(info)),
		where,
		vim.fn.fnamemodify(info.cwd or "", ":~"),
		project,
		info.pid,
		started
	)
end

return M
