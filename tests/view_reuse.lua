-- nvim --headless -u NONE -l tests/view_reuse.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns, vim.o.lines = 200, 60
local view = require("replconnect.view")
local layout = require("replconnect.layout")
local Plots = require("replconnect.plots")
require("replconnect.config").set({
	completion = false,
	layout = {
		external = [[ editor | (plots \ view) @ 30% ]],
	},
	plots = { auto_open = true, renderer = "external" },
})
local pending, display = {}, nil
local client = { language = "julia", info = { capabilities = { "plots" } } }
function client:request(method, params, success, failure)
	pending[#pending + 1] = { method = method, params = params, success = success, failure = failure }
end
function client:on(_, callback) display = callback; return function() end end
local editor = vim.api.nvim_get_current_win()
local plots
local function bufs() return { plots = plots.buf, view = view.buffer(client) } end
plots = Plots.init(client, nil, function() return layout.show("plots", bufs()) end,
	function() return not layout.blocked("plots", bufs()) end)
view.set_opener(client, function()
	return layout.show("view", bufs(), { hide = { plots = function() plots:hide() end } })
end)
local function page(value)
	return { names = { "x" }, types = { "Int" }, rows = { { value or "1" } }, row_labels = { "1" },
		offset = 0, total_rows = 1, total_columns = 1 }
end
local function title()
	return vim.api.nvim_buf_get_lines(view.buffer(client), 0, 1, false)[1]
end
local function flush() vim.wait(20, function() return false end) end
local function select(name)
	view.open(client, { name })
	return pending[#pending]
end

plots:open(true, false)
local original_notify = vim.notify
vim.notify = function() end
select("missing").failure({ message = "not found" })
vim.notify = original_notify
assert(plots:winid() and view.buffer(client) == nil, "failed first selection leaves plots visible")
select("first").success(page())
flush()
local buf = view.buffer(client)
local win = vim.fn.bufwinid(buf)
assert(win ~= -1 and not plots:winid(), "viewer replaces plots")
assert(title():find("first", 1, true))

-- Second selection reuses both the buffer and window; starts at page zero.
local second = select("second")
assert(second.params.offset == 0 and second.params.slice == nil)
second.success(page("2"))
flush()
assert(view.buffer(client) == buf and vim.fn.bufwinid(buf) == win)
assert(title():find("second", 1, true))
assert(#vim.api.nvim_tabpage_list_wins(0) == 2)

-- Whichever request finishes first, the latest requested selection wins.
local old, newest = select("old"), select("newest")
newest.success(page("3")); old.success(page("4"))
flush()
assert(title():find("newest", 1, true))
old, newest = select("old-again"), select("latest")
old.success(page("4")); newest.success(page("5"))
flush()
assert(title():find("latest", 1, true))

-- Failed selections leave the old contents AND their refresh bindings usable.
local notify = vim.notify
vim.notify = function() end
select("bad").failure({ message = "no such variable" })
vim.notify = notify
assert(title():find("latest", 1, true))
local refresh = vim.api.nvim_buf_call(buf, function() return vim.fn.maparg("r", "n", false, true).callback end)
refresh()
assert(pending[#pending].params.path[1] == "latest")
pending[#pending].success(page()); flush()

-- A page reply from the previous selection cannot overwrite a new variable.
refresh()
local stale_page = pending[#pending]
select("after-page").success(page("6")); flush()
stale_page.success(page("old data")); flush()
assert(title():find("after-page", 1, true))

-- Automatic plot events accumulate history but never evict the viewer.
local path = vim.fn.tempname() .. ".png"
vim.fn.writefile({ "image" }, path)
display({ id = 1, mime = "image/png", path = path })
assert(not plots:winid() and vim.fn.bufwinid(buf) == win)
assert(#plots.records == 1)

-- Closing the viewer restores the plot pane it replaced.
vim.api.nvim_win_close(vim.fn.bufwinid(buf), true); flush()
assert(plots:winid() and vim.fn.bufwinid(buf) == -1)
select("switch-back").success(page()); flush()
assert(not plots:winid() and vim.fn.bufwinid(buf) ~= -1)

plots:open(true, false)
assert(plots:winid() and vim.fn.bufwinid(buf) == -1)
assert(vim.api.nvim_buf_is_valid(buf), "hidden viewers retain their buffer")
-- Closing plots restores the same viewer, including its selected variable.
plots:hide(); flush()
assert(vim.fn.bufwinid(buf) ~= -1 and not plots:winid())
assert(title():find("switch-back", 1, true))
-- Repeated switches do not create cycles: after restoring view, close it and
-- the area disappears because the old plots entry was removed from history.
vim.api.nvim_win_close(vim.fn.bufwinid(buf), true); flush()
assert(not plots:winid() and vim.fn.bufwinid(buf) == -1)
plots:open(true, false)
select("reopened").success(page()); flush()
assert(view.buffer(client) == buf and not plots:winid())

-- A wiped viewer can be opened again; session teardown invalidates pending replies.
vim.api.nvim_buf_delete(buf, { force = true })
select("after-wipe").success(page()); flush()
assert(view.buffer(client) ~= buf)
local late = select("after-detach")
view.forget(client)
late.success(page()); flush()
assert(view.buffer(client) == nil)
assert(#vim.api.nvim_tabpage_list_wins(0) == 1)
plots:wipe()
vim.fn.delete(path)
vim.api.nvim_set_current_win(editor)
print("viewer reuse and exclusivity tests passed")
