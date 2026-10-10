-- Run from the repository root: nvim --headless -u NONE -l tests/vars.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local Vars = require("replconnect.vars")
local config = require("replconnect.config")
config.set()

local function var(name, kind, has_children)
	return {
		access_key = name, display_name = name, display_value = "value of " .. name,
		display_type = "T", kind = kind or "number", has_children = has_children or false,
	}
end

-- A fake client answering synchronously from a table of handlers.
local calls = {}
local handlers = {}
local client = {
	pid = 1, language = "julia", closed = false,
	request = function(_, method, params, on_result, on_error)
		table.insert(calls, { method = method, params = params })
		-- a handler returns (result) or (nil, err), like a request that failed or timed out
		local result, err = handlers[method](params)
		if err then
			if on_error then on_error(err) end
		else
			on_result(result)
		end
	end,
}

handlers.list = function()
	return { variables = { var("x"), var("df", "table", true), var("f", "function") }, length = 3, version = 4 }
end
handlers.inspect = function()
	return { children = { var("a"), var("b") }, length = 2 }
end

local pane = Vars.init(client)
local function lines() return vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false) end
local function text() return table.concat(lines(), "\n") end

-- open: lists and groups by category
pane:open()
assert(pane.version == 4 and pane.length == 3)
assert(calls[#calls].method == "list")
assert(vim.bo[pane.buf].filetype == "inspectvars")
local t = text()
assert(t:find("DATA", 1, true) and t:find("FUNCTIONS", 1, true) and t:find("VALUES", 1, true), t)
assert(t:find("value of x", 1, true))
assert(vim.bo[pane.buf].modifiable == false)

-- expanding fetches children once and shows them
pane:expand({ "df" })
assert(calls[#calls].method == "inspect" and vim.deep_equal(calls[#calls].params.path, { "df" }))
assert(text():find("value of a", 1, true))
pane:collapse({ "df" })
assert(not text():find("value of a", 1, true))

-- sync: same version → nothing else; diff → upsert/remove; refresh → relist
local function count_calls(method)
	return vim.tbl_count(vim.tbl_filter(function(c) return c.method == method end, calls))
end
handlers.status = function() return { version = 4, busy = false } end
handlers.changes = function() return { version = 4 } end
local changes_calls = count_calls("changes")
pane:sync()
assert(calls[#calls].method == "status")
assert(count_calls("changes") == changes_calls, "unchanged version must not ask for changes")
assert(pane.version == 4 and #pane.vars == 3)

handlers.status = function() return { version = 6, busy = false } end
handlers.changes = function()
	return { version = 6, assigned = { var("y"), var("x") }, removed = { "f" } }
end
pane:sync()
assert(pane.version == 6)
local keys = vim.tbl_map(function(v) return v.access_key end, pane.vars)
table.sort(keys)
assert(vim.deep_equal(keys, { "df", "x", "y" }), vim.inspect(keys))
assert(not text():find("FUNCTIONS", 1, true))

local list_calls = vim.tbl_count(vim.tbl_filter(function(c) return c.method == "list" end, calls))
handlers.status = function() return { version = 9, busy = false } end
handlers.changes = function() return { version = 9, refresh = true } end
pane:sync()
assert(vim.tbl_count(vim.tbl_filter(function(c) return c.method == "list" end, calls)) == list_calls + 1)
assert(pane.version == 4) -- the fake list answers version 4

-- delete removes only what the server reports deleted
handlers.delete = function() return { "x" } end
pane:delete("x")
assert(calls[#calls].method == "delete" and vim.deep_equal(calls[#calls].params.names, { "x" }))
assert(not pane:get_var({ "x" }) and pane:get_var({ "df" }))

-- excluded variables are hidden; multi-line values stay on one line
config.set({ exclude = { "df" } })
pane:redraw()
assert(not text():find("df", 1, true))
config.set()
pane.vars[1].display_value = "line1\nline2"
pane:redraw()
assert(text():find("line1 line2", 1, true))

-- columns: the type keeps at least 15 cells (or all it needs) and is hidden first
assert(vim.deep_equal({ Vars._layout(80, 10, 30) }, { 10, 40, 24 }))
assert(vim.deep_equal({ Vars._layout(40, 10, 30) }, { 10, 9, 15 }))
assert(vim.deep_equal({ Vars._layout(80, 10, 5) }, { 10, 59, 5 }))
assert(vim.deep_equal({ Vars._layout(30, 10, 30) }, { 10, 16, 0 }), "too narrow: type hidden")

-- the type is left-aligned right after the value column, without trailing blanks
local long_type = "Dict{Symbol, Vector{Float64}}"
pane.vars[1].display_type = long_type
vim.api.nvim_win_set_width(pane:winid(), 60)
pane:redraw()
local row = vim.tbl_filter(function(l) return l:find("Dict{", 1, true) end, lines())[1]
assert(row and row:find("  Dict{Symbol, Vec", 1, true), row) -- 18 of 60 cells
assert(not row:find("%s$"), row)
vim.api.nvim_win_set_width(pane:winid(), 30)
pane:redraw()
assert(not text():find("Dict{", 1, true), "narrow pane hides the type")
pane.vars[1].display_type = "T"

-- header: busy (the server says so), stale (no answer in time), recovery
local function header() return vim.wo[pane:winid()].winbar end
assert(header():find("julia", 1, true) and header():find("pid 1", 1, true))
assert(not header():find("evaluating", 1, true))

handlers.status = function() return { version = pane.version, busy = true } end
pane:sync()
assert(pane.busy and header():find("evaluating", 1, true))

-- while evaluating, the workspace is not scanned (that would slow the computation)
handlers.status = function() return { version = pane.version + 1, busy = true } end
local before_busy = count_calls("changes")
pane:sync()
assert(pane.busy and count_calls("changes") == before_busy, "must not fetch changes while busy")
handlers.changes = function() return { version = pane.version + 1 } end
config.set({ update_while_busy = true })
pane:sync()
assert(count_calls("changes") == before_busy + 1, "update_while_busy opts in")
config.set()

handlers.status = function() return nil, { code = -32000, message = "request timed out: status" } end
pane:sync()
assert(pane.stale and header():find("showing last known values", 1, true))
assert(pane.syncing == false, "a timed-out sync must not block the next one")

handlers.status = function() return { version = pane.version, busy = false } end
pane:sync()
assert(not pane.stale and not pane.busy and not header():find("busy", 1, true))

-- while busy or silent, a visible pane keeps checking and clears the marker by itself
Vars.RETRY_MS = 20
handlers.status = function() return nil, { code = -32000, message = "request timed out: status" } end
pane:sync()
assert(pane.stale)
handlers.status = function() return { version = pane.version, busy = false } end
assert(vim.wait(2000, function() return not pane.stale end), "marker must clear without user action")
assert(not header():find("busy", 1, true))
vim.wait(150) -- let any pending debounced trigger fire first
local idle_calls = #calls
vim.wait(100)
assert(#calls == idle_calls, "no polling once the REPL is idle")

-- no retries for a hidden pane
handlers.status = function() return nil, { code = -32000, message = "request timed out: status" } end
pane:sync()
assert(pane.stale)
vim.wait(0)
local hidden_calls = #calls
vim.api.nvim_win_close(pane:winid(), true)
vim.wait(100)
assert(#calls == hidden_calls, "a hidden pane must not poll")
pane:open()
Vars.RETRY_MS = 1000
handlers.status = function() return { version = pane.version, busy = false } end
pane:sync()

-- a '%' in the text must not be read as a winbar item
client.language = "ju%lia"
pane:update_header()
assert(header():find("ju%%lia", 1, true))
client.language = "julia"

-- a closed client is not synced, and the pane says the REPL is gone
client.closed = true
local n = #calls
pane:sync()
assert(#calls == n)
assert(header():find("REPL exited", 1, true))

print("variables pane tests passed")
