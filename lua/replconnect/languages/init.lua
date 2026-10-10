-- Registry of REPL languages. Each entry describes how to launch its REPL and
-- the editor details that differ between languages (filetypes, prompt,
-- completion triggers). Everything else in the plugin is language-neutral.
--
-- The core ships no languages. Each language is its own plugin
-- (replconnect-julia, replconnect-r, ...) that calls `register` when loaded
-- (from its `plugin/` directory), so languages install independently.

local M = {}

---@class replconnect.Language
---@field name string protocol language (`initialize` result `language`)
---@field label string human-readable name
---@field filetypes string[] buffers whose runtime completions come from this REPL
---@field prompt string prompt shown before inputs in session previews
---@field trigger_characters string[]
---@field command string[] default launch command
---@field plot_capture boolean whether the service can capture plots (`repl.capture_plots`)
---@field plots_hint string how to enable plot capture in the REPL
---@field stop_hint string how to stop the service from the REPL
---@field build_cmd fun(opts: replconnect.ReplConfig, extra?: string[]): string[], table<string, string>?
---@field startup_hint? string what to check when the service never enables requested capabilities
---@field repl? replconnect.ReplConfig options from the language plugin's own `setup()`

local REQUIRED = {
	name = "string",
	label = "string",
	filetypes = "table",
	prompt = "string",
	trigger_characters = "table",
	command = "table",
	plot_capture = "boolean",
	plots_hint = "string",
	stop_hint = "string",
	build_cmd = "function",
}

---Registered languages by name, and their registration order.
---@type table<string, replconnect.Language>
local registry = {}
local order = {}

---Register a language (replacing any earlier one of the same name).
---@param language replconnect.Language
function M.register(language)
	assert(type(language) == "table", "language must be a table")
	for field, expected in pairs(REQUIRED) do
		assert(type(language[field]) == expected,
			("language `%s`: field `%s` must be a %s"):format(tostring(language.name), field, expected))
	end
	if not registry[language.name] then
		order[#order + 1] = language.name
	end
	registry[language.name] = language
end

---Apply a language plugin's `setup(opts)`: its :REPLStart options (same
---fields as the core's `repl`, e.g. `command`), then (re-)register it.
---Language plugins implement `setup` as `languages.configure(M, opts)`.
---@param language replconnect.Language
---@param opts? replconnect.ReplConfig
function M.configure(language, opts)
	assert(opts == nil or type(opts) == "table", ("%s setup: options must be a table"):format(language.label))
	language.repl = vim.deepcopy(opts or {})
	M.register(language)
end

---Remove a registered language (mainly for tests).
---@param name string
function M.unregister(name)
	registry[name] = nil
	order = vim.tbl_filter(function(n)
		return n ~= name
	end, order)
end

---Registered language names, in registration order.
---@return string[]
function M.names()
	return vim.list_extend({}, order)
end

---Validated plot capture options shared by every launcher.
---@param opts replconnect.ReplConfig
---@return boolean capture
---@return integer limit
function M.plot_options(opts)
	assert(opts.capture_plots == nil or type(opts.capture_plots) == "boolean", "repl.capture_plots must be a boolean")
	local limit = opts.plot_limit == nil and 50 or opts.plot_limit
	assert(type(limit) == "number" and limit > 0 and limit < math.huge and limit % 1 == 0,
		"repl.plot_limit must be a positive integer")
	return opts.capture_plots == true, limit
end

---@param name string
---@return replconnect.Language?
function M.get(name)
	return registry[name]
end

---All registered languages.
---@return replconnect.Language[]
function M.all()
	return vim.tbl_map(M.get, order)
end

---The language whose filetypes include `filetype`, or nil.
---@param filetype string
---@return replconnect.Language?
function M.for_filetype(filetype)
	for _, language in ipairs(M.all()) do
		if vim.tbl_contains(language.filetypes, filetype) then
			return language
		end
	end
end

---Which language a command run from a buffer refers to, in order:
--- 1. the buffer's filetype (an R buffer means R, even if only Julia is attached);
--- 2. the language whose pane or REPL terminal the buffer is (`owner`);
--- 3. the only attached language.
---Returns nil when nothing applies; `ambiguous` is true when several languages
---are attached and the caller should ask.
---@param ctx { filetype?: string, owner?: string, attached: string[] }
---@return string? language
---@return boolean ambiguous
function M.resolve(ctx)
	local language = ctx.filetype and M.for_filetype(ctx.filetype)
	if language then
		return language.name, false
	end
	if ctx.owner then
		return ctx.owner, false
	end
	if #ctx.attached == 1 then
		return ctx.attached[1], false
	end
	return nil, #ctx.attached > 1
end

---Human-readable name for a language name (the name itself if unregistered).
---@param name string
---@return string
function M.label(name)
	local language = M.get(name)
	return language and language.label or name
end

return M
