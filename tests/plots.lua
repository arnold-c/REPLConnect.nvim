-- nvim --headless -u NONE -l tests/plots.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local Plots = require("replconnect.plots")
local config = require("replconnect.config")
local renders, clears = {}, 0
local renderer = { render = function(record) renders[#renders + 1] = record.id end,
	clear = function() clears = clears + 1 end }
config.set({ plots = { renderer = renderer, auto_open = true } })
assert(config.options.plots.keymaps.next == "<C-n>")
assert(config.options.plots.keymaps.previous == "<C-p>")
local requests, handler, unsubscribed = {}, nil, false
local client = { language = "julia", closed = false, info = { capabilities = { "plots" } } }
function client:on(method, fn)
	assert(method == "display")
	handler = fn
	return function() unsubscribed = true end
end
function client:request(method, params, callback)
	requests[#requests + 1] = { method = method, callback = callback }
end
local dir = vim.fn.tempname()
vim.fn.mkdir(dir)
local function record(id, mime)
	local path = dir .. "/" .. id .. (mime == "image/svg+xml" and ".svg" or ".png")
	vim.fn.writefile({ "image " .. id }, path)
	return { id = id, mime = mime or "image/png", path = path }
end
local one, two, three, four = record(1), record(2), record(3, "image/svg+xml"), record(4)
local focus = vim.api.nvim_get_current_win()
local layout = require("replconnect.layout")
local repl = require("replconnect.repl")
local term_buf = vim.api.nvim_create_buf(false, true)
local term_win = repl.open_split({ split = "horizontal", size = 7 }, term_buf)
vim.api.nvim_set_current_win(focus)
local pane
pane = Plots.init(client, nil, function() return layout.show("plots", { repl = term_buf, plots = pane.buf }) end)
assert(requests[1].method == "plots_subscribe" and handler)
-- Live events before the snapshot callback are not lost; duplicates sorted.
handler(two)
assert(vim.api.nvim_get_current_win() == focus and pane:winid())
assert(vim.api.nvim_win_get_width(term_win) == vim.o.columns, "auto-open must keep horizontal terminal full width")
assert(vim.api.nvim_win_get_position(pane:winid())[1] < vim.api.nvim_win_get_position(term_win)[1])
requests[1].callback({ plots = { two, one } })
assert(#pane.records == 2 and pane.records[1].id == 1 and pane.selected == 2)
assert(renders[#renders] == 2)
local function mapped_action(key)
	local mapping = vim.api.nvim_buf_call(pane.buf, function()
		return vim.fn.maparg(key, "n", false, true)
	end)
	assert(mapping.buffer == 1 and type(mapping.callback) == "function")
	mapping.callback()
end
mapped_action("<C-p>")
assert(pane.selected == 1 and not pane.follow)
mapped_action("<C-n>")
assert(pane.selected == 2 and not pane.follow)
mapped_action("<C-p>")
assert(pane.selected == 1 and not pane.follow)
handler(three)
assert(pane.selected == 1)
pane:latest()
assert(pane.selected == 3 and pane.follow)
pane:move(1)
assert(not pane.follow and pane.selected == 3)
pane:refresh()
local pending = requests[#requests]
handler(four)
pending.callback({ plots = { two, three } })
assert(#pane.records == 3 and pane.records[1].id == 2 and pane.selected == 3)
pane:latest()
assert(pane.selected == 4)
-- Only resizing the plot window redraws; unrelated floats (completion menus)
-- resize while typing and must not make the image flicker.
local before = #renders
local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false,
	{ relative = "editor", row = 0, col = 0, width = 10, height = 2 })
pane:resized({ float })
pane:resized(nil)
assert(#renders == before, "unrelated resize must not redraw plots")
vim.api.nvim_win_close(float, true)
pane:resized({ focus, pane:winid() })
assert(#renders == before + 1, "resizing the plot window must redraw it")
-- Fullscreen float covers the editor, receives the render, and toggles back.
local split_win = pane:winid()
before = #renders
mapped_action("<C-e>")
local full = pane:fullscreen_win()
assert(full and pane:winid() == full and vim.api.nvim_get_current_win() == full)
assert(vim.api.nvim_win_get_config(full).relative == "editor")
assert(vim.api.nvim_win_get_width(full) == vim.o.columns)
assert(#renders == before + 1)
mapped_action("<C-e>")
assert(not pane:fullscreen_win() and pane:winid() == split_win)
assert(vim.wait(1000, function() return #renders == before + 2 end), "closing fullscreen must redraw the pane")
before = #renders
pane:hide()
assert(not pane:winid() and clears > 0)
config.options.plots.auto_open = false -- pane retains its own options table
pane.opts.auto_open = false
handler(four)
assert(not pane:winid() and #renders == before)
pane:open(false, false)
assert(vim.api.nvim_get_current_win() == focus)
assert(vim.api.nvim_win_get_width(term_win) == vim.o.columns, "manual reopen must keep terminal full width")
-- Resolve placement again after the terminal layout changes.
pane:hide()
vim.api.nvim_win_close(term_win, true)
term_win = repl.open_split({ split = "vertical", size = 30 }, term_buf)
vim.api.nvim_set_current_win(focus)
pane:open(false, false)
assert(vim.api.nvim_get_current_win() == focus)
assert(vim.api.nvim_win_get_width(pane:winid()) == vim.api.nvim_win_get_width(term_win))
assert(vim.api.nvim_win_get_position(pane:winid())[2] == vim.api.nvim_win_get_position(term_win)[2])
assert(vim.api.nvim_win_get_position(pane:winid())[1] < vim.api.nvim_win_get_position(term_win)[1])
pane:hide()
vim.api.nvim_win_close(term_win, true)
term_win = nil
pane:open(false, false)
assert(vim.api.nvim_get_current_win() == focus)
assert(vim.api.nvim_win_get_height(pane:winid()) == vim.api.nvim_win_get_height(focus))
-- Expired files are actionable, never passed to the renderer.
vim.fn.delete(four.path)
before = #renders
pane:draw()
assert(#renders == before)
assert(table.concat(vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false), "\n"):find("expired"))
pane:refresh()
requests[#requests].callback({ plots = { three } })
assert(#pane.records == 1 and pane.selected == 3)
-- A saved copy outlives the original and preserves its extension/bytes.
local destination = vim.fn.tempname() .. ".svg"
pane:save(destination)
assert(vim.fn.filereadable(destination) == 1)
assert(vim.deep_equal(vim.fn.readfile(destination, "b"), vim.fn.readfile(three.path, "b")))
-- Saving must not overwrite an existing destination.
vim.fn.writefile({ "keep existing contents" }, destination)
local original_notify = vim.notify
local save_error
vim.notify = function(message, level) save_error = { message = message, level = level } end
pane:save(destination)
vim.notify = original_notify
assert(save_error and save_error.level == vim.log.levels.ERROR)
assert(vim.deep_equal(vim.fn.readfile(destination), { "keep existing contents" }))
vim.fn.delete(three.path)
assert(vim.fn.filereadable(destination) == 1)
local late = handler
pane:refresh()
local stale = requests[#requests].callback
pane:wipe()
assert(unsubscribed and not pane:valid())
late(one)
stale({ plots = { one } })
assert(#pane.records == 1)
assert(Plots.init({ info = { capabilities = {} } }) == nil)
assert(require("replconnect.renderers").create("external").name == "external")
-- An unavailable renderer explains itself instead of leaving a blank pane.
config.set({ plots = { renderer = { render = function() end, clear = function() end, reason = "no terminal" } } })
local explained = Plots.init(client, nil)
explained:merge({ one })
explained:open(true, false)
assert(table.concat(vim.api.nvim_buf_get_lines(explained.buf, 0, -1, false), "\n"):find("No image renderer: no terminal"))
explained:wipe()
vim.fn.delete(destination)
vim.fn.delete(dir, "rf")
print("plot pane tests passed")
