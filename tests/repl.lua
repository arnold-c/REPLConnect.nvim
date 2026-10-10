-- Run from the repository root: nvim --headless -u NONE -l tests/repl.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local config = require("replconnect.config")
local repl = require("replconnect.repl")
local languages = require("replconnect.languages")

local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end

local fake = dofile("tests/support/fake_languages.lua")()
local julia, r = fake.julia, fake.r

-- defaults: a vertical split running the language's command, entering terminal mode
config.set()
eq(config.options.repl.split, "vertical")
eq(config.options.repl.enter, true)
eq(config.options.repl.capture_plots, false)
eq(config.options.repl.plot_limit, 50)
eq(config.repl_options(julia).command, { "julia" })
eq(config.repl_options(r).command, { "arf" })
eq(config.repl_options(julia).julia, nil) -- per-language tables are not settings
-- user options merge over the defaults; per-language tables override shared fields
config.set({ repl = { split = "horizontal", size = 15, r = { command = { "arf", "--vanilla" }, split = "vertical" } } })
eq(config.options.repl.split, "horizontal")
eq(config.options.repl.size, 15)
eq(config.repl_options(julia).command, { "julia" })
eq(config.repl_options(julia).split, "horizontal")
eq(config.repl_options(r).command, { "arf", "--vanilla" })
eq(config.repl_options(r).split, "vertical")
eq(config.repl_options(r).size, 15)
-- a language plugin's own setup() layers over the shared fields; repl.<language> still wins
languages.configure(julia, { command = { "julia", "--project=." }, size = 20 })
eq(config.repl_options(julia).command, { "julia", "--project=." })
eq(config.repl_options(julia).size, 20)
eq(config.repl_options(julia).split, "horizontal")
config.set({ repl = { julia = { command = { "julia", "+1.12" } } } })
eq(config.repl_options(julia).command, { "julia", "+1.12" })
eq(config.repl_options(julia).size, 20)
config.set()
languages.configure(julia, nil)
eq(config.repl_options(julia).command, { "julia" })
assert(not pcall(languages.configure, julia, "julia"), "setup options must be a table")
languages.configure(julia, nil)
config.set({ repl = { split = "horizontal", size = 15, r = { command = { "arf", "--vanilla" }, split = "vertical" } } })
-- a flat repl.command is ignored (commands are per language), with a warning
local warned
local notify_before = vim.notify
vim.notify = function(msg) warned = msg end
config.set({ repl = { command = { "julia", "+1.12" } } })
vim.notify = notify_before
assert(warned and warned:find("repl.<language>.command", 1, true), warned)
eq(config.repl_options(julia).command, { "julia" })
eq(config.repl_options(r).command, { "arf" })
eq(config.options.repl.command, nil)
config.set()

-- the language registry: registered languages are found by name and filetype
eq(languages.names(), { "julia", "r" })
assert(languages.for_filetype("r") == r and languages.for_filetype("rmd") == r)
assert(languages.get("julia") == julia)
eq(languages.get("cobol"), nil)
assert(languages.for_filetype("julia") == julia)
eq(languages.for_filetype("lua"), nil)
eq(julia.command, { "julia" })
eq(julia.prompt, "julia> ")

-- command line: the adapter's build_cmd, through the shared entry point
eq(repl.build_cmd(julia, { command = { "julia", "+1.12" } }, { "--project=." }), { "julia", "+1.12", "--project=." })

-- Plot capture is only requested from services that support it.
config.set({ repl = { capture_plots = true, size = 9 } })
eq(julia.plot_capture, true)
eq(r.plot_capture, true)
eq(repl.launch_options(julia).capture_plots, true)
eq(repl.launch_options(r).capture_plots, true)
eq(repl.launch_options(r, { split = "horizontal" }).split, "horizontal")
eq(repl.launch_options(r).size, 9)
local no_capture = vim.tbl_extend("force", r, { name = "nocap", plot_capture = false })
eq(repl.launch_options(no_capture).capture_plots, false)
config.set()

-- :REPLStart arguments: leading direction > modifiers > config
local split, switches = repl.parse_args({ "horizontal", "--project=." }, {})
eq(split, "horizontal")
eq(switches, { "--project=." })
split, switches = repl.parse_args({ "--project=." }, { horizontal = true })
eq(split, "horizontal")
eq(switches, { "--project=." })
split = repl.parse_args({}, { vertical = true })
eq(split, "vertical")
split = repl.parse_args({ "vertical" }, { horizontal = true })
eq(split, "vertical")
split, switches = repl.parse_args({}, {})
eq(split, nil)
eq(switches, {})
-- only the first argument is a direction; later words are Julia's
split, switches = repl.parse_args({ "--project=.", "horizontal" }, nil)
eq(split, nil)
eq(switches, { "--project=.", "horizontal" })
-- leading words may also name the language, in either order
local language
split, switches, language = repl.parse_args({ "r", "horizontal", "--vanilla" }, nil)
eq({ split, switches, language }, { "horizontal", { "--vanilla" }, "r" })
split, switches, language = repl.parse_args({ "vertical", "julia", "r" }, nil)
eq({ split, switches, language }, { "vertical", { "r" }, "julia" })
split, switches, language = repl.parse_args({ "--project=.", "r" }, { vertical = true })
eq({ split, switches, language }, { "vertical", { "--project=.", "r" }, nil })
-- the caller's list is not modified
local fargs = { "horizontal" }
repl.parse_args(fargs)
eq(fargs, { "horizontal" })

-- splits: vertical by default, horizontal on request, optional size
local start_wins = #vim.api.nvim_list_wins()
local scratch = vim.api.nvim_create_buf(false, true)
local win = repl.open_split({ split = "vertical", size = 30 }, scratch)
assert(vim.api.nvim_win_get_width(win) == 30)
assert(vim.api.nvim_win_get_buf(win) == scratch)
assert(vim.api.nvim_win_get_height(win) >= vim.o.lines - 3, "vertical: full height")
vim.api.nvim_win_close(win, true)
win = repl.open_split({ split = "horizontal", size = 7 }, scratch)
assert(vim.api.nvim_win_get_height(win) == 7)
assert(vim.api.nvim_win_get_width(win) == vim.o.columns, "horizontal: full width")
vim.api.nvim_win_close(win, true)
assert(not vim.bo[scratch].buflisted)
assert(#vim.api.nvim_list_wins() == start_wins)

-- a missing executable is reported, and no split is left behind
local notified
local original = vim.notify
vim.notify = function(msg, level) notified = { msg = msg, level = level } end
config.set({ repl = { julia = { command = { "definitely-not-a-julia-binary" } } } })
assert(repl.start("julia") == nil)
assert(notified and notified.level == vim.log.levels.ERROR and notified.msg:find("repl.julia.command", 1, true))
config.set({ repl = { r = { command = { "definitely-not-arf" } } } })
assert(repl.start("r") == nil)
assert(notified.msg:find("repl.r.command", 1, true), notified.msg)
assert(repl.start("cobol") == nil)
assert(notified.msg:find("unknown language", 1, true), notified.msg)
assert(#vim.api.nvim_list_wins() == start_wins)

-- a command written as one string (quotes inside a single list item) gets a hint
config.set({ repl = { julia = { command = { 'julia", "--project=.' } } } })
assert(repl.start("julia") == nil)
assert(notified.msg:find("own list item", 1, true), notified.msg)
vim.notify = original
config.set()

-- pane placement next to the REPL terminal (default layouts)
local layout = require("replconnect.layout")
local editor = vim.api.nvim_get_current_win()
local pos = vim.api.nvim_win_get_position
local term_buf = vim.api.nvim_create_buf(false, true)
local pane_buf = vim.api.nvim_create_buf(false, true)

-- terminal as a right-hand column: the pane goes above it, in that column
local term_win = repl.open_split({ split = "vertical", size = 30 }, term_buf)
eq(vim.b[term_buf].replconnect_layout, "vertical")
vim.api.nvim_set_current_win(editor)
local pane_win = layout.show("vars", { repl = term_buf, vars = pane_buf })
eq(vim.api.nvim_get_current_win(), editor) -- the caller decides about focus
eq(pos(pane_win)[2], pos(term_win)[2])
assert(pos(pane_win)[1] < pos(term_win)[1])
eq(vim.api.nvim_win_get_width(term_win), 30) -- the column keeps its width
vim.api.nvim_win_close(pane_win, true)
vim.api.nvim_win_close(term_win, true)

-- terminal full width at the bottom: the pane is beside the editor above it
term_win = repl.open_split({ split = "horizontal", size = 7 }, term_buf)
eq(vim.b[term_buf].replconnect_layout, "horizontal")
vim.api.nvim_set_current_win(editor)
pane_win = layout.show("vars", { repl = term_buf, vars = pane_buf })
eq(vim.api.nvim_win_get_width(term_win), vim.o.columns) -- terminal still full width
eq(vim.api.nvim_win_get_height(term_win), 7)
eq(pos(pane_win)[1], pos(editor)[1])
assert(pos(pane_win)[2] > pos(editor)[2])
eq(vim.api.nvim_win_get_width(pane_win), layout.PANE_WIDTH)
vim.api.nvim_win_close(pane_win, true)
vim.api.nvim_win_close(term_win, true)

-- no visible terminal: a full-height column on the right
pane_win = layout.show("vars", { repl = term_buf, vars = pane_buf })
eq(vim.api.nvim_win_get_height(pane_win), vim.api.nvim_win_get_height(editor))
assert(pos(pane_win)[2] > pos(editor)[2])
vim.api.nvim_win_close(pane_win, true)

-- The launcher carries its readiness requirements into the eventual attach.
local discover = require("replconnect.discover")
local plugin = require("replconnect")
local original_list, original_attach, original_poll = discover.list, plugin.attach, repl.POLL_MS
local attach_info = { terminal_buf = term_buf }
local required = { required_capabilities = { "plots" }, ready_timeout_ms = 1000 }
local older = { terminal_buf = term_buf, started_at = 5 }
local attached
discover.list = function() return { older, attach_info } end
attach_info.started_at = 10
plugin.attach = function(info, opts) attached = { info = info, opts = opts } end
repl.POLL_MS = 10
repl.attach_when_ready(term_buf, { exited = false }, { attach = required, newer_than = 7 })
-- While launching, commands explain what attachment is waiting for.
local original_notify, warning = vim.notify, nil
vim.notify = function(message) warning = message end
plugin.open_plots()
assert(warning:find("not attached yet: waiting for REPL in terminal buffer", 1, true))
assert(vim.wait(1000, function() return attached ~= nil end))
assert(attached.info == attach_info and attached.opts == required)
plugin.open_plots()
assert(warning:find("run :REPLAttach", 1, true))
vim.notify = original_notify
discover.list, plugin.attach, repl.POLL_MS = original_list, original_attach, original_poll

-- Launched REPLs learn their editor's pid and are stopped when Neovim exits,
-- even one that ignores SIGTERM and SIGHUP (SIGKILL after the grace period).
discover.list = function() return {} end
plugin.setup({ completion = false }) -- registers the VimLeavePre cleanup
local editor_pid = tostring(vim.fn.getpid())
local function launch(script)
	config.set({ repl = { enter = false, julia = { command = { "sh", "-c", script } } } })
	local buf = assert(repl.start("julia"))
	return vim.b[buf].terminal_job_id
end
-- Exits at once (code 1) unless the editor pid is in its environment.
local polite = launch(('test "$%s" = %s && exec sleep 60'):format(repl.EDITOR_PID_ENV, editor_pid))
local stubborn = launch("trap '' TERM HUP; exec sleep 60")
vim.wait(200)
eq(vim.fn.jobwait({ polite, stubborn }, 0), { -1, -1 })
eq(#repl.launched_pids(), 2)
repl.KILL_GRACE_S = 0.2
vim.api.nvim_exec_autocmds("VimLeavePre", {})
local codes = vim.fn.jobwait({ polite, stubborn }, 3000)
assert(codes[1] ~= -1 and codes[2] ~= -1, vim.inspect(codes))
eq(#repl.launched_pids(), 0)
discover.list = original_list
config.set()

print("repl tests passed")
