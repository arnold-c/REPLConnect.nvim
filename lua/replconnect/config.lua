---@class replconnect.Config
---Top-level variables to hide from the variables pane: a list of names, or a
---predicate receiving the variable (`access_key`, `display_type`, `kind`, ...)
---and returning true to hide it.
---REPLConnect already hides names starting with `_` or `#`.
---Exclusion is client-side only and does not prevent lookup or deletion.
---@field exclude? string[] | fun(var: table): boolean
---@field viewer? replconnect.ViewerConfig
---@field plots? replconnect.PlotsConfig
---Serve runtime completions to each language's buffers through an in-process
---LSP server while a REPL of that language is attached. Default true.
---@field completion? boolean
---Refresh the variables pane this often (ms) while it is visible, for setups
---without focus events. 0 (default) disables polling.
---@field poll_interval_ms? integer
---Fetch variable changes even while the REPL is evaluating (it answers only if
---the running code yields). Off by default: each fetch scans the workspace on
---the REPL's thread and can slow a yielding computation down.
---@field update_while_busy? boolean
---How `:REPLStart` launches a REPL.
---@field repl? replconnect.ReplConfig
---Where the REPL terminal, variables and plot panes go; see `replconnect.layout`.
---@field layout? replconnect.LayoutConfig

---A layout string: pane names (editor, repl, vars, plots, view) combined with
---| (side by side), / (stacked), \ (exclusive alternatives), parentheses and
---@ sizes (`@ 35%` of the enclosing region, `@ 60` cells).
---@alias replconnect.LayoutString string

---@class replconnect.LayoutConfig
---Layout while the REPL terminal is a horizontal split.
---@field horizontal? replconnect.LayoutString | fun(ctx: { mode: string, visible: string[] }): replconnect.LayoutString
---Layout while the REPL terminal is a vertical split.
---@field vertical? replconnect.LayoutString | fun(ctx: { mode: string, visible: string[] }): replconnect.LayoutString
---Layout when the REPL is not in a visible Neovim terminal.
---@field external? replconnect.LayoutString | fun(ctx: { mode: string, visible: string[] }): replconnect.LayoutString

---Settings for REPLs launched by :REPLStart. The fields apply to every
---language. Per-language settings (e.g. `command`) normally go to the language
---plugin's own `setup()`; `repl.<language>` here still overrides them.
---@class replconnect.ReplConfig
---Where the terminal opens: "vertical" (default) or "horizontal".
---@field split? "vertical" | "horizontal"
---Width (vertical) or height (horizontal) of the split; nil keeps Neovim's default half.
---@field size? integer
---Executable and leading arguments, e.g. `repl.julia.command = { "julia", "+1.12" }`.
---Set it per language (`repl.<language>.command`); a top-level one is ignored.
---@field command? string[]
---Start in terminal mode so you can type straight away. Default true.
---@field enter? boolean
---Enable service-side plot capture for REPLs launched by :REPLStart. Default false.
---@field capture_plots? boolean
---Maximum retained plot files in a newly enabled store. Default 50.
---@field plot_limit? integer

---@alias replconnect.Keybinding string | string[] | false

---@class replconnect.ViewerKeymaps
---@field close? replconnect.Keybinding
---@field refresh? replconnect.Keybinding
---@field next_page? replconnect.Keybinding
---@field previous_page? replconnect.Keybinding
---@field scroll_right? replconnect.Keybinding
---@field scroll_left? replconnect.Keybinding
---@field next_slice? replconnect.Keybinding
---@field previous_slice? replconnect.Keybinding
---@field select_slice? replconnect.Keybinding Mouse binding for selecting slice tabs.

---@class replconnect.ViewerConfig
---@field keymaps? replconnect.ViewerKeymaps | false Set false to disable all viewer mappings.

---@class replconnect.PlotsConfig
---@field renderer? "auto" | "snacks" | "image.nvim" | "external" | table Custom {render(record, {buf, win}), clear()} closures.
---@field remote? boolean | "auto" Stream plot images through the terminal (Snacks) instead of sending file paths. "auto" (default) streams over SSH when snacks.nvim is loaded; true/false force it on/off.
---@field auto_open? boolean Show new plots without stealing focus; default false.
---@field keymaps? table<string, replconnect.Keybinding> | false Actions: close, next, previous, refresh, follow, external, save.

local M = {}

local defaults = {
	completion = true,
	poll_interval_ms = 0,
	update_while_busy = false,
	repl = {
		split = "vertical",
		enter = true,
		capture_plots = false,
		plot_limit = 50,
		-- Per-language overrides go in `repl.<language>`; `command` defaults to the
		-- language's (see replconnect.languages).
	},
	layout = {
		-- Side panes beside the editor; the terminal stays full width.
		horizontal = "(editor | vars | plots | view) / repl",
		-- Side panes stacked above the terminal, in its column.
		vertical = "editor | (vars / plots / view / repl)",
		-- A 60-column stack on the right.
		external = "editor | (vars / plots / view) @ 60",
	},
	plots = {
		renderer = "auto",
		remote = "auto",
		auto_open = false,
		keymaps = { close = "q", next = "<C-n>", previous = "<C-p>", refresh = "r",
			follow = "f", external = "o", save = "s" },
	},
	viewer = {
		keymaps = {
			close = "q",
			refresh = "r",
			next_page = "]p",
			previous_page = "[p",
			scroll_right = "<Tab>",
			scroll_left = "<S-Tab>",
			next_slice = { "<C-n>", "]s" },
			previous_slice = { "<C-p>", "[s" },
			select_slice = "<LeftMouse>",
		},
	},
}

---@type replconnect.Config
M.options = vim.deepcopy(defaults)

---Replace options by merging opts over fresh defaults.
---Existing viewers retain the keymaps captured when they were opened.
---@param opts? replconnect.Config
M.set = function(opts)
	opts = opts or {}
	local layout = require("replconnect.layout")
	local user_layout = opts.layout or {}
	assert(type(user_layout) == "table", "layout must be a table of layout strings")
	for key in pairs(user_layout) do
		if not vim.tbl_contains(layout.MODES, key) then
			error(("layout.%s is not an option; use horizontal, vertical or external"):format(tostring(key)), 0)
		end
	end
	local misplaced = vim.tbl_filter(function(key)
		return type(opts.repl) == "table" and opts.repl[key] ~= nil
	end, vim.list_extend({}, layout.MODES))
	if #misplaced > 0 then
		vim.notify(("replconnect: repl.%s is ignored; layouts go under `layout = { ... }`")
			:format(table.concat(misplaced, ", repl.")), vim.log.levels.WARN)
	end
	local options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
	if options.repl.command ~= nil then
		vim.notify("replconnect: repl.command is ignored; set repl.<language>.command, e.g. repl.julia.command",
			vim.log.levels.WARN)
		options.repl.command = nil
	end
	for _, mode in ipairs(layout.MODES) do
		if type(options.layout[mode]) ~= "function" then
			local source, path = options.layout[mode], "layout." .. mode
			layout.warn_sizes(source, (layout.parse(source, path)), path)
		end
	end
	M.options = options
end

---Effective :REPLStart settings for `language`, later layers winning: its
---default command, the shared `repl` fields, the options given to the language
---plugin's own `setup()`, then `repl.<language>` here (kept as an override).
---@param language replconnect.Language
---@return replconnect.ReplConfig
function M.repl_options(language)
	local languages = require("replconnect.languages")
	local shared = {}
	for key, value in pairs(M.options.repl) do
		if not languages.get(key) then
			shared[key] = value
		end
	end
	return vim.tbl_extend("force", { command = language.command }, shared, language.repl or {},
		M.options.repl[language.name] or {})
end

return M
