-- Launch a REPL in a Neovim terminal split and attach to it once its
-- REPLConnect server is up (the equivalent of starting a kernel in jet.nvim).
-- The language-specific command line comes from `replconnect.languages`.

local config = require("replconnect.config")
local discover = require("replconnect.discover")
local languages = require("replconnect.languages")

local uv = vim.uv or vim.loop

local M = {}

M.POLL_MS = 500
M.TIMEOUT_MS = 90000 -- the REPL may precompile or install on first start

---Environment variable telling a launched REPL's service which editor owns
---it, so it can exit if that editor dies without stopping it.
M.EDITOR_PID_ENV = "REPLCONNECT_EDITOR_PID"

---Seconds a REPL gets to exit on SIGTERM when Neovim exits, before SIGKILL.
M.KILL_GRACE_S = 3

---Running REPL jobs started by `start`: job id -> pid.
---@type table<integer, integer>
local launched = {}

---Stop every REPL this Neovim launched: SIGTERM now and, from a detached
---helper that outlives Neovim, SIGKILL after `KILL_GRACE_S` if it is still
---running. Called on VimLeavePre, so a REPL never outlives its editor, even
---when its terminal does not end it (e.g. it ignores SIGHUP or is stuck).
function M.stop_launched()
	for job, pid in pairs(launched) do
		launched[job] = nil
		if vim.fn.jobwait({ job }, 0)[1] == -1 then
			pcall(uv.kill, pid, "sigterm")
			pcall(vim.system, {
				"sh", "-c", ("sleep %s; kill -0 %d 2>/dev/null && kill -KILL %d"):format(M.KILL_GRACE_S, pid, pid),
			}, { detach = true })
			pcall(vim.fn.jobstop, job)
		end
	end
end

---Pids of the running REPLs this Neovim launched (for tests and diagnostics).
---@return integer[]
function M.launched_pids()
	return vim.tbl_values(launched)
end

---The launch command line for `language`.
---@param language replconnect.Language
---@param opts replconnect.ReplConfig
---@param extra? string[] extra REPL switches
---@return string[] cmd
---@return table<string, string>? env
function M.build_cmd(language, opts, extra)
	return language.build_cmd(opts, extra)
end

---Show `bufnr` where the `layout.horizontal` or `layout.vertical` tree puts
---"repl" (by default a full-width split at the bottom, or a full-height one
---on the right) and focus it. The buffer remembers the split, so later panes
---use the same layout.
---@param opts { split: "vertical" | "horizontal", size?: integer }
---@param bufnr integer
---@return integer win
function M.open_split(opts, bufnr)
	local mode = opts.split == "horizontal" and "horizontal" or "vertical"
	vim.b[bufnr].replconnect_layout = mode
	local win = require("replconnect.layout").show("repl", { repl = bufnr }, { mode = mode, repl_size = opts.size })
	vim.api.nvim_set_current_win(win)
	return win
end

local function notify(msg, level)
	vim.notify("replconnect: " .. msg, level or vim.log.levels.INFO)
end

---Whether the job of terminal buffer `bufnr` is still running (true when the
---buffer has no job id, e.g. in tests).
---@param bufnr integer
---@return boolean
function M.job_running(bufnr)
	local job = vim.b[bufnr].terminal_job_id
	return type(job) ~= "number" or vim.fn.jobwait({ job }, 0)[1] == -1
end

---@class replconnect.WaitOptions
---@field attach? table options for `attach` (required capabilities)
---@field label? string language shown in messages (default "REPL")
---@field newer_than? integer only sessions started after this (`started_at`)
---@field quiet? boolean no warning when giving up

---Poll for the session started in terminal buffer `bufnr`, then attach to it.
---Gives up when the buffer or job goes away, or after `TIMEOUT_MS`.
---@param bufnr integer
---@param job_state { exited: boolean }
---@param opts? replconnect.WaitOptions
function M.attach_when_ready(bufnr, job_state, opts)
	opts = opts or {}
	local label = opts.label or "REPL"
	local timer = uv.new_timer()
	local waited = 0
	local inspect = require("replconnect")
	inspect.set_pending(("waiting for %s in terminal buffer %d to start a REPLConnect server"):format(label, bufnr))
	local stop = function()
		inspect.set_pending(nil)
		if not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
	timer:start(
		M.POLL_MS,
		M.POLL_MS,
		vim.schedule_wrap(function()
			waited = waited + M.POLL_MS
			if job_state.exited or not vim.api.nvim_buf_is_valid(bufnr) or not M.job_running(bufnr) then
				return stop()
			end
			for _, info in ipairs(discover.list()) do
				if info.terminal_buf == bufnr and (not opts.newer_than or (info.started_at or 0) > opts.newer_than) then
					stop()
					return inspect.attach(info, opts.attach)
				end
			end
			if waited >= M.TIMEOUT_MS then
				stop()
				if not opts.quiet then
					notify(("the %s session did not start a REPLConnect server; see docs/quickstart.md"):format(label),
						vim.log.levels.WARN)
				end
			end
		end)
	)
end

M.SPLITS = { vertical = true, horizontal = true }

---Split direction, language and REPL switches from `:REPLStart` arguments
---and modifiers. Leading words may name a split direction and a language, in
---either order; everything after them is passed to the REPL. A direction
---argument wins over `:vertical`/`:horizontal` modifiers, which win over the
---configured `repl.split`.
---@param fargs string[]
---@param smods? { vertical?: boolean, horizontal?: boolean }
---@return "vertical" | "horizontal" | nil split nil: use the configured default
---@return string[] switches
---@return string? language nil: use the current buffer's
function M.parse_args(fargs, smods)
	local args = vim.list_extend({}, fargs or {})
	local split, language
	while args[1] do
		if not split and M.SPLITS[args[1]] then
			split = table.remove(args, 1)
		elseif not language and languages.get(args[1]) then
			language = table.remove(args, 1)
		else
			break
		end
	end
	if not split and smods and smods.horizontal then
		split = "horizontal"
	elseif not split and smods and smods.vertical then
		split = "vertical"
	end
	return split, args, language
end

---Effective settings for launching `language`: its configured `repl` options
---with `overrides`, and plot capture off where the service cannot capture.
---@param language replconnect.Language
---@param overrides? replconnect.ReplConfig
---@return replconnect.ReplConfig
function M.launch_options(language, overrides)
	local opts = vim.tbl_extend("force", config.repl_options(language), overrides or {})
	if not language.plot_capture then
		opts.capture_plots = false
	end
	return opts
end

---Start a REPL in a terminal split and attach to it when ready.
---@param name string language, e.g. "julia" or "r"
---@param extra? string[] extra REPL switches
---@param overrides? replconnect.ReplConfig e.g. `{ split = "horizontal" }` for this start only
---@return integer? bufnr the terminal buffer, or nil if the REPL could not be started
function M.start(name, extra, overrides)
	local language = languages.get(name)
	if not language then
		notify(("unknown language `%s`; registered: %s (install a replconnect-<language> plugin)")
			:format(tostring(name), table.concat(languages.names(), ", ")),
			vim.log.levels.ERROR)
		return nil
	end
	local opts = M.launch_options(language, overrides)
	if vim.fn.executable(opts.command[1]) ~= 1 then
		local hint = opts.command[1]:find("[%s\"']")
				and ("; each argument must be its own list item, e.g. { %q, \"--project=.\" }"):format(language.command[1])
			or ""
		notify(
			("cannot run `%s`; set `repl.%s.command` in setup()%s"):format(opts.command[1], language.name, hint),
			vim.log.levels.ERROR
		)
		return nil
	end

	local ok, cmd, env = pcall(M.build_cmd, language, opts, extra)
	if not ok then
		notify(tostring(cmd), vim.log.levels.ERROR)
		return nil
	end

	-- An unlisted scratch buffer (as jet.nvim does), so the REPL does not show up in
	-- buffer lists or bufferline tabs.
	env = vim.tbl_extend("force", env or {}, { [M.EDITOR_PID_ENV] = tostring(vim.fn.getpid()) })
	local bufnr = vim.api.nvim_create_buf(false, true)
	local win = M.open_split(opts, bufnr)
	local state = { exited = false }
	local job = vim.api.nvim_buf_call(bufnr, function()
		return vim.fn.jobstart(cmd, {
			term = true,
			cwd = vim.fn.getcwd(),
			env = env,
			on_exit = function(id, code)
				launched[id] = nil
				state.exited = true
				-- Close after a clean exit; keep the buffer if the REPL failed, so its
				-- output can be read.
				if code == 0 then
					vim.schedule(function()
						if vim.api.nvim_buf_is_valid(bufnr) then
							pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
						end
					end)
				end
			end,
		})
	end)
	if job <= 0 then
		pcall(vim.api.nvim_win_close, win, true)
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		notify("failed to start " .. language.label, vim.log.levels.ERROR)
		return nil
	end
	launched[job] = vim.fn.jobpid(job)
	-- jobstart names the buffer after the command line; use something readable.
	vim.bo[bufnr].buflisted = false
	pcall(vim.api.nvim_buf_set_name, bufnr, ("%s REPL (%d)"):format(language.name, vim.fn.jobpid(job)))
	if opts.enter then
		vim.cmd.startinsert()
	end
	M.attach_when_ready(bufnr, state, {
		attach = {
			required_capabilities = opts.capture_plots and { "plots" } or nil,
			ready_timeout_ms = M.TIMEOUT_MS,
		},
		label = language.label,
	})
	return bufnr
end

return M
