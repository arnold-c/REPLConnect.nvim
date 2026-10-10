-- replconnect: attach Neovim to plain REPLs (Julia, R/arf) running REPLConnect.
--
-- Usage:
--   require("replconnect").setup()
--   :REPLAttach [pid]   pick (or give the pid of) a running REPL session
--   :REPLDetach [language]
--   :REPLStop[!] [language]  stop the session's server (! also closes its terminal REPL)
--
-- One session is attached per language. Commands act on the language of the
-- current buffer (see `languages.resolve`): its filetype, else the pane or
-- REPL terminal it belongs to, else the only attached session, else they ask.
--
-- Other modules (variables pane, viewer, completion LSP) get the attached
-- client through `require("replconnect").client(language)`.

local discover = require("replconnect.discover")
local languages = require("replconnect.languages")
local socket = require("replconnect.socket")

local M = {}

---One attached client per language.
---@type table<string, replconnect.SocketClient>
local clients = {}

---@type fun(client: replconnect.SocketClient)[]
local attach_listeners = {}

---What an unfinished launch/attach is waiting for, reported instead of "not attached".
---@type string?
local pending

---Record (or clear, with nil) the attachment in progress.
---@param description? string
function M.set_pending(description)
	pending = description
end

---Variables pane per language.
---@type table<string, replconnect.Vars>
local panes = {}
local plot_panes = {}

local function drop_plots(language)
	local pane = plot_panes[language]
	plot_panes[language] = nil
	if pane then pane:wipe() end
end

local pane_opener
local reconnect_after_restart
-- Command bodies, run once the language is known (defined below).
local open_vars_for, open_view_for, stop_for, capture_layout_for

---Neovim terminal buffer hosting each language's REPL, when it runs in one.
---@type table<string, integer>
local hosts = {}

---Resolve buffers afresh for both explicit opening and auto-open checks.
local function pane_buffers(language)
	local vars, plots, client = panes[language], plot_panes[language], clients[language]
	return {
		repl = hosts[language],
		vars = vars and vars:valid() and vars.buf or nil,
		plots = plots and plots:valid() and plots.buf or nil,
		view = client and require("replconnect.view").buffer(client),
	}
end

---Replace the client's plot pane; nil when the service does not capture plots.
local function attach_plots(client)
	drop_plots(client.language)
	plot_panes[client.language] = require("replconnect.plots").init(client, nil, pane_opener(client.language, "plots"), function()
		return not require("replconnect.layout").blocked("plots", pane_buffers(client.language))
	end)
end

---Opens pane `name` ("vars", "plots" or "view") through the configured layout, which
---also rearranges the REPL terminal and the other pane; resolved on each open.
---@param language string
---@param name string
---@return replconnect.WindowOpener
function pane_opener(language, name)
	return function()
		local vars, plots = panes[language], plot_panes[language]
		local bufs, hide = pane_buffers(language), {}
		if plots and plots:valid() then
			hide.plots = function() plots:hide() end
		end
		return require("replconnect.layout").show(name, bufs, {
			hide = hide,
			on_restore = function(restored)
				if restored == "plots" and plots and plots.alive then plots:draw() end
				if restored == "vars" and vars and vars:valid() then vars:redraw() end
			end,
		})
	end
end

---Ask a visible pane to sync (debounced); hidden panes sync when they are opened.
local function sync_pane(language)
	local pane = panes[language]
	if pane and pane:valid() and pane:winid() then
		pane.request_sync()
	end
end

local function drop_pane(language)
	local pane = panes[language]
	panes[language] = nil
	if pane then
		pane:wipe()
	end
end

---Names of the languages with an attached client, sorted.
---@return string[]
local function attached_languages()
	local names = vim.tbl_keys(clients)
	table.sort(names)
	return names
end

---The language whose pane, viewer or REPL terminal `bufnr` is, or nil.
---@param bufnr integer
---@return string?
local function owner(bufnr)
	local names = vim.tbl_keys(vim.tbl_extend("keep", {}, clients, panes, plot_panes, hosts))
	table.sort(names)
	for _, language in ipairs(names) do
		for _, buf in pairs(pane_buffers(language)) do
			if buf == bufnr then
				return language
			end
		end
	end
end

---The language commands run from `bufnr` refer to (see `languages.resolve`).
---@param bufnr? integer default: the current buffer
---@return string? language
---@return boolean ambiguous several sessions are attached and none applies
function M.language(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	return languages.resolve({
		filetype = vim.bo[bufnr].filetype,
		owner = owner(bufnr),
		attached = attached_languages(),
	})
end

---Run `fn(language)` for an explicit language, else the current buffer's;
---asks which session when that is ambiguous. Returns `fn`'s result when no
---question was needed.
---@generic T
---@param language? string
---@param fn fun(language?: string): T
---@return T?
local function with_language(language, fn)
	if language then
		return fn(language)
	end
	local resolved, ambiguous = M.language()
	if not ambiguous then
		return fn(resolved)
	end
	vim.ui.select(attached_languages(), {
		prompt = "Which REPL?",
		format_item = languages.label,
	}, function(choice)
		if choice then
			fn(choice)
		end
	end)
end

---Attached client for `language` (default: the current buffer's language,
---when that is unambiguous), or nil.
---@param language? string
---@return replconnect.SocketClient?
function M.client(language)
	language = language or M.language()
	return language and clients[language] or nil
end

---Call `fn(client)` after every successful attach.
function M.on_attach(fn)
	attach_listeners[#attach_listeners + 1] = fn
end

local function notify(msg, level)
	vim.notify("replconnect: " .. msg, level or vim.log.levels.INFO)
end

---Follow capture being enabled or disabled at runtime (`capture_plots!`).
---A new pane subscribes and recovers the fresh history; ids restart with it.
local function watch_capabilities(client)
	client:on("capabilities", function(params)
		if clients[client.language] ~= client or type(params) ~= "table" or type(params.capabilities) ~= "table" then
			return
		end
		local had = plot_panes[client.language] ~= nil
		client.info.capabilities = params.capabilities
		if had == require("replconnect.plots").supported(client) then return end
		attach_plots(client)
		notify(had and "plot capture disabled" or "plot capture enabled")
	end)
end

---How long after a disconnect a still-running terminal job means a restart.
M.RESTART_GRACE_MS = 200

---A session in a Neovim terminal disconnected while its terminal job keeps
---running: the REPL restarted in place (arf's `:restart`/`:switch` exec and
---keep the pid). Wait for the new generation's server and attach to it.
---@param client replconnect.SocketClient the closed client
---@param host? integer its terminal buffer
---@return boolean waiting
function reconnect_after_restart(client, host)
	local repl = require("replconnect.repl")
	if not host or not vim.api.nvim_buf_is_valid(host) or not repl.job_running(host) then
		return false
	end
	notify(("%s session disconnected; reconnecting when it restarts (or :REPLAttach)")
		:format(client.language), vim.log.levels.WARN)
	repl.attach_when_ready(host, { exited = false }, {
		label = languages.label(client.language),
		newer_than = client.info and client.info.started_at or 0,
		quiet = true,
	})
	return true
end

---Attach to a discovered session record.
function M.attach(info, opts)
	opts = opts or {}
	local required = opts.required_capabilities or {}
	M.set_pending(("connecting to pid %d%s"):format(info.pid,
		#required > 0 and ("; waiting for the service to enable: " .. table.concat(required, ", ")) or ""))
	socket.connect(info.socket, {
		required_capabilities = opts.required_capabilities,
		ready_timeout_ms = opts.ready_timeout_ms,
		on_close = function()
			for language, c in pairs(clients) do
				if c.closed then
					local host = hosts[language]
					require("replconnect.view").forget(c)
					drop_plots(language)
					clients[language] = nil
					hosts[language] = nil
					-- Keep the pane (its last values stay readable) but mark it detached.
					if panes[language] then
						panes[language]:update_header()
					end
					-- An exiting REPL closes the connection just before its job ends.
					vim.defer_fn(function()
						if clients[language] then
							return -- attached again meanwhile
						end
						if not reconnect_after_restart(c, host) then
							notify(language .. " session disconnected; :REPLAttach to reconnect", vim.log.levels.WARN)
						end
					end, M.RESTART_GRACE_MS)
				end
			end
		end,
	}, function(err, client)
		M.set_pending(nil)
		if err then
			return notify(err, vim.log.levels.ERROR)
		end
		local previous = clients[client.language]
		if previous then require("replconnect.view").forget(previous) end
		require("replconnect.view").set_opener(client, pane_opener(client.language, "view"))
		clients[client.language] = client
		drop_pane(client.language)
		hosts[client.language] = require("replconnect.terminal").host_buffer(client.pid)
		attach_plots(client)
		watch_capabilities(client)
		if previous then
			previous.on_close = nil
			previous:close()
		end
		notify(
			("attached to %s %s (pid %d%s)"):format(
				client.language,
				client.info.language_version,
				client.pid,
				hosts[client.language] and (", in Neovim terminal buffer %d"):format(hosts[client.language]) or ""
			)
		)
		for _, fn in ipairs(attach_listeners) do
			fn(client)
		end
	end)
end

---Drop all editor state for `language` and close its connection quietly.
local function forget(language)
	local client = clients[language]
	if client then require("replconnect.view").forget(client) end
	clients[language] = nil
	hosts[language] = nil
	drop_pane(language)
	drop_plots(language)
	if client then
		client.on_close = nil
		client:close()
	end
	require("replconnect.lsp").stop(language)
end

---Detach from the session of `language` (default: the current buffer's).
---@param language? string
function M.detach(language)
	with_language(language, function(name)
		local client = name and clients[name]
		if not client then
			return notify(name and ("no %s session attached"):format(languages.label(name)) or "not attached",
				vim.log.levels.WARN)
		end
		forget(client.language)
		notify("detached")
	end)
end

---The attached client, or nil after telling the user to attach first.
---@param language? string
---@return replconnect.SocketClient?
local function require_client(language)
	local client = language and clients[language]
	if not client or client.closed then
		local what = language and ("no %s session attached"):format(languages.label(language)) or "not attached"
		notify(pending and ("not attached yet: " .. pending) or (what .. "; run :REPLAttach"), vim.log.levels.WARN)
		return nil
	end
	return client
end

---Toggle the variables pane for the attached session.
---@param language? string default: the current buffer's
function M.open_vars(language)
	return with_language(language, function(name)
		local pane = panes[name]
		local win = pane and pane:valid() and pane:winid()
		if win then return vim.api.nvim_win_close(win, true) end
		open_vars_for(name)
	end)
end

function open_vars_for(language)
	local client = require_client(language)
	if not client then
		return
	end
	local pane = panes[client.language]
	if not pane or not pane:valid() or pane.client ~= client then
		drop_pane(client.language)
		pane = require("replconnect.vars").init(client)
		panes[client.language] = pane
	end
	pane:open(pane_opener(client.language, "vars"))
end

---Toggle the plot pane without interrupting capture.
---@param language? string default: the current buffer's
function M.open_plots(language)
	return with_language(language, function(name)
		local client = require_client(name)
		if not client then return end
		local pane = plot_panes[client.language]
		if not pane then
			local registered = languages.get(client.language)
			return notify("plots unavailable" .. (registered and ("; " .. registered.plots_hint) or ""),
				vim.log.levels.WARN)
		end
		if pane:winid() then pane:hide() else pane:open() end
	end)
end

---Toggle (or set) whether Snacks streams plot images instead of sending file
---paths, then redraw visible plot panes. Streaming is needed when the
---terminal runs on another machine, e.g. over SSH.
---@param on? boolean
---@return boolean? remote
function M.toggle_plots_remote(on)
	local remote, err = require("replconnect.renderers").snacks_remote(on)
	if remote == nil then return notify(err, vim.log.levels.WARN) end
	for _, pane in pairs(plot_panes) do pane:draw() end
	notify("plot images: " .. (remote and "streamed (remote)" or "file paths (local)"))
	return remote
end

---Stop the attached session's REPLConnect server and detach. The REPL keeps
---running unless `quit` is set and it runs in a Neovim terminal (for example
---one whose window was closed): then that terminal and the REPL are closed too.
---@param language? string default: the current buffer's
---@param quit? boolean
function M.stop(language, quit)
	return with_language(language, function(name)
		stop_for(name, quit)
	end)
end

function stop_for(language, quit)
	local client = require_client(language)
	if not client then
		return
	end
	local label = languages.label(client.language)
	if not vim.tbl_contains(client.info.capabilities or {}, "shutdown") then
		local registered = languages.get(client.language)
		return notify("this REPLConnect cannot be stopped from Neovim; update it"
			.. (registered and (", or " .. registered.stop_hint) or ""), vim.log.levels.WARN)
	end
	local host, pid, on_close = hosts[client.language], client.pid, client.on_close
	client.on_close = nil -- the disconnect that follows is expected
	local finished = false
	local function done()
		if finished then
			return
		end
		finished = true
		if clients[client.language] == client then
			forget(client.language)
		end
		if quit and host and vim.api.nvim_buf_is_valid(host) then
			pcall(vim.api.nvim_buf_delete, host, { force = true }) -- ends the REPL job
			notify(("stopped and closed the %s REPL (pid %d)"):format(label, pid))
		else
			notify(("stopped the REPLConnect server (pid %d)%s"):format(pid,
				quit and ("; %s is not in a Neovim terminal, so it keeps running"):format(label) or ""))
		end
	end
	client:request("shutdown", vim.empty_dict(), done, function(err)
		-- The server may close the connection before its reply is read.
		if err and err.message == "connection closed" then
			return done()
		end
		client.on_close = on_close
		notify("stop failed: " .. tostring(err and err.message), vim.log.levels.ERROR)
	end)
end

---Open the grid viewer for a dotted access path such as `df` or `nt.field`;
---without a path, use the variable under the cursor in the variables pane.
---@param path? string
---@param language? string default: the current buffer's
function M.open_view(path, language)
	return with_language(language, function(name)
		open_view_for(path, name)
	end)
end

function open_view_for(path, language)
	local client = require_client(language)
	if not client then
		return
	end
	local keys
	if path and path ~= "" then
		keys = vim.split(path, ".", { plain = true })
	else
		local pane = panes[client.language]
		local var = pane and vim.api.nvim_get_current_buf() == pane.buf and pane:current_var()
		if not var then
			return notify("give a variable name, or run from the variables pane", vim.log.levels.WARN)
		end
		keys = var.path
	end
	require("replconnect.view").open(client, keys)
end

---Start a REPL for `language` (default: the current buffer's; asks when no
---buffer, pane or single attached session decides) in a terminal split and
---attach to it when ready.
---@param language? string
---@param switches? string[] extra REPL switches
---@param overrides? replconnect.ReplConfig
function M.start(language, switches, overrides)
	local function start(name)
		require("replconnect.repl").start(name, switches, overrides)
	end
	language = language or M.language()
	if language then
		return start(language)
	end
	vim.ui.select(languages.names(), { prompt = "Start which REPL?", format_item = languages.label }, function(choice)
		if choice then
			start(choice)
		end
	end)
end

---Attach to the session with `pid`, or pick one if there are several.
function M.pick(pid)
	local dirs = discover.dirs()
	local sessions = discover.list({ dirs = dirs })
	if pid then
		sessions = vim.tbl_filter(function(s)
			return s.pid == pid
		end, sessions)
	end
	if #sessions == 0 then
		return notify(
			"no running REPL found in:\n  "
				.. table.concat(dirs, "\n  ")
				.. "\nstart a REPL with REPLConnect, or use :REPLStart (see docs/quickstart.md)",
			vim.log.levels.WARN
		)
	end
	if #sessions == 1 then
		return M.attach(sessions[1])
	end
	require("replconnect.picker").select(sessions, M.attach)
end

local completion_listener = false

---Attach `bufnr` to the completion server of its filetype's language, if
---completion is enabled and that language has an attached session.
---@param bufnr integer
local function attach_completion(bufnr)
	if require("replconnect.config").options.completion == false then
		return
	end
	local language = languages.for_filetype(vim.bo[bufnr].filetype)
	if language and clients[language.name] then
		require("replconnect.lsp").attach_buffer(bufnr, language, function()
			return clients[language.name]
		end)
	end
end

---Attach completion to every loaded buffer of `language`'s filetypes.
---@param language string
local function attach_completion_all(language)
	local registered = languages.get(language)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if registered and vim.api.nvim_buf_is_loaded(bufnr)
			and vim.tbl_contains(registered.filetypes, vim.bo[bufnr].filetype) then
			attach_completion(bufnr)
		end
	end
end

---The optional language argument of a command (nil when empty).
local function language_arg(cmd)
	return cmd.args ~= "" and cmd.args or nil
end

local function complete_language(arglead)
	return vim.tbl_filter(function(name)
		return vim.startswith(name, arglead)
	end, languages.names())
end

---@param opts? replconnect.Config
function M.setup(opts)
	require("replconnect.config").set(opts)
	if not completion_listener then
		completion_listener = true
		M.on_attach(function(client)
			attach_completion_all(client.language)
		end)
	end
	-- A REPL in a Neovim terminal: its variables may have changed whenever the
	-- user leaves that buffer (back to normal mode, or to another window).
	vim.api.nvim_create_autocmd({ "TermLeave", "WinLeave", "BufLeave" }, {
		group = vim.api.nvim_create_augroup("replconnect.terminal", { clear = true }),
		callback = function(args)
			for language, host in pairs(hosts) do
				if args.buf == host then
					sync_pane(language)
				end
			end
		end,
	})
	vim.api.nvim_create_autocmd("FileType", {
		group = vim.api.nvim_create_augroup("replconnect.completion", { clear = true }),
		-- No pattern: languages register when their plugin loads, possibly after
		-- setup(); `attach_completion` looks the filetype up each time.
		callback = function(args)
			attach_completion(args.buf)
		end,
	})
	vim.api.nvim_create_user_command("REPLAttach", function(opts)
		M.pick(tonumber(opts.args))
	end, { nargs = "?", desc = "Attach to a REPL running REPLConnect" })
	vim.api.nvim_create_user_command("REPLStart", function(opts)
		local repl = require("replconnect.repl")
		local split, switches, language = repl.parse_args(opts.fargs, opts.smods)
		M.start(language, switches, { split = split })
	end, {
		nargs = "*",
		complete = function(arglead, cmdline)
			-- Offer a direction and a language as the leading words only.
			local words = vim.split(vim.trim(cmdline), "%s+")
			local typed = arglead == "" and #words - 1 or #words - 2
			if typed >= 2 then
				return {}
			end
			return vim.tbl_filter(function(s)
				return vim.startswith(s, arglead)
			end, vim.list_extend({ "vertical", "horizontal" }, languages.names()))
		end,
		desc = "Start a REPL in a terminal split and attach: [vertical|horizontal] [language] [REPL switches]",
	})
	vim.api.nvim_create_user_command("REPLDetach", function(cmd)
		M.detach(language_arg(cmd))
	end, { nargs = "?", complete = complete_language, desc = "Detach from a REPL: [language]" })
	vim.api.nvim_create_user_command("REPLStop", function(cmd)
		M.stop(language_arg(cmd), cmd.bang)
	end, { bang = true, nargs = "?", complete = complete_language,
		desc = "Stop the REPL's REPLConnect server (! also closes a REPL in a Neovim terminal): [language]" })
	vim.api.nvim_create_user_command("REPLVariables", function(cmd)
		M.open_vars(language_arg(cmd))
	end, { nargs = "?", complete = complete_language, desc = "Open the variables pane: [language]" })
	vim.api.nvim_create_user_command("REPLPlots", function(cmd) M.open_plots(language_arg(cmd)) end,
		{ nargs = "?", complete = complete_language, desc = "Toggle plot history: [language]" })
	vim.api.nvim_create_user_command("REPLPlotsRemote", function(cmd)
		M.toggle_plots_remote(({ on = true, off = false })[cmd.args])
	end, { nargs = "?", complete = function() return { "on", "off" } end,
		desc = "Toggle or set streaming plot images to a remote terminal (Snacks)" })
	vim.api.nvim_create_user_command("REPLVariableViewer", function(cmd)
		M.open_view(cmd.args)
	end, { nargs = "?", desc = "View a table or array in a grid" })
	vim.api.nvim_create_user_command("REPLLayout", function(cmd)
		M.capture_layout(cmd.bang)
	end, { bang = true, desc = "Capture the current pane sizes as a layout string (! also use it this session)" })
end

---Measure the current pane arrangement as a layout string, copy it to the
---clipboard and unnamed registers, and show it. With `apply`, also use it for
---its mode for the rest of the session (your config file is not changed).
---@param apply? boolean
---@param language? string default: the current buffer's
---@return replconnect.LayoutCapture?
function M.capture_layout(apply, language)
	return with_language(language, function(name)
		return capture_layout_for(apply, name)
	end)
end

function capture_layout_for(apply, language)
	local capture = require("replconnect.layout_capture")
	local ok, result = pcall(capture.capture, pane_buffers(language))
	if not ok then
		return notify("cannot capture the layout: " .. tostring(result), vim.log.levels.ERROR)
	end
	local line = ("%s = [[ %s ]],"):format(result.mode, result.layout)
	vim.fn.setreg('"', line)
	pcall(vim.fn.setreg, "+", line)
	if apply then
		require("replconnect.config").options.layout[result.mode] = result.layout
	end
	notify(capture.describe(result) .. "\nCopied; paste it into `layout = { ... }` in your config."
		.. (apply and ("\nUsing it for layout.%s for the rest of this session."):format(result.mode) or ""))
	return result
end

return M
