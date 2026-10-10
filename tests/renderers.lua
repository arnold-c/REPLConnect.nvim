-- nvim --headless -u NONE -l tests/renderers.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
-- The renderer messages depend on SSH detection; do not inherit the caller's.
vim.env.SSH_CONNECTION, vim.env.SSH_CLIENT, vim.env.SSH_TTY = nil, nil, nil
local renderers = require("replconnect.renderers")
local placement, image, closed, cleared, opts, src
local supports = true
package.loaded["snacks.image"] = {
	supports_terminal = function() return supports end,
	placement = { new = function(buf, path, options)
		assert(buf == vim.api.nvim_get_current_buf())
		opts, src = options, path
		placement = { close = function() closed = true end }
		return placement
	end },
}
package.loaded["image"] = { from_file = function(path, options)
	opts, src = options, path
	image = { render = function() image.rendered = true end, clear = function() cleared = true end }
	return image
end }
local ctx = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win() }
local record = { id = 1, mime = "image/svg+xml", path = "/tmp/example.svg" }
local adapter = renderers.create("auto")
assert(adapter.name == "Snacks")
adapter.render(record, ctx)
assert(opts.inline and opts.auto_resize and opts.max_width > 0 and src == record.path)
adapter.clear()
assert(closed)
supports = false
adapter = renderers.create("auto")
assert(adapter.name == "image.nvim")
adapter.render(record, ctx)
assert(image.rendered and src == record.path and opts.buffer == ctx.buf and opts.window == ctx.win)
adapter.clear()
assert(cleared)
local fallback = renderers.create("snacks")
assert(fallback.name == "external" and fallback.reason:find("did not detect"))
assert(not fallback.reason:find("SSH"))
vim.env.SSH_CONNECTION = "10.0.0.1 5000 10.0.0.2 22"
assert(renderers.create("snacks").reason:find("SNACKS_KITTY=1"))
vim.env.SSH_CONNECTION = nil
package.loaded["image"] = nil
package.preload["image"] = function() error("missing") end
fallback = renderers.create("auto")
assert(fallback.name == "external" and fallback.reason:find("image.nvim not installed"))
assert(renderers.create("external").name == "external")
assert(renderers.create("external").reason == nil)
local custom = { render = function() end, clear = function() end }
assert(renderers.create(custom) == custom)
-- Remote toggle: resets Snacks' cached env so SNACKS_SSH is re-read, and
-- forgets sent images so the current terminal receives them again.
local resets, image_clears = 0, 0
local terminal = {}
function terminal.env()
	if not terminal._env then
		resets = resets + 1
		terminal._env = { remote = vim.env.SNACKS_SSH == "1" or nil }
	end
	return terminal._env
end
package.loaded["snacks.image.terminal"] = terminal
package.loaded["snacks.image.image"] = { clear = function() image_clears = image_clears + 1 end }
vim.env.SNACKS_SSH = nil
assert(renderers.snacks_remote() == true and vim.env.SNACKS_SSH == "1")
assert(renderers.snacks_remote() == false and vim.env.SNACKS_SSH == "0")
assert(renderers.snacks_remote(false) == false)
assert(renderers.snacks_remote(true) == true)
assert(image_clears == 4 and resets == 5)
-- `plots.remote`: applied once, when a Snacks renderer is created.
local function remote_after(setting, ssh, snacks_loaded)
	renderers.reset_remote()
	vim.env.SNACKS_SSH = nil
	vim.env.SSH_TTY = ssh and "/dev/pts/1" or nil
	package.loaded["snacks"] = snacks_loaded and {} or nil
	terminal._env = nil
	renderers.create("auto", setting)
	local value = vim.env.SNACKS_SSH
	vim.env.SSH_TTY = nil
	return value
end
assert(remote_after(nil, true, true) == nil, "unset leaves Snacks alone")
assert(remote_after(true, false, false) == "1")
assert(remote_after(false, true, true) == "0")
assert(remote_after("auto", true, true) == "1")
assert(remote_after("auto", true, false) == nil, "auto needs Snacks loaded")
assert(remote_after("auto", false, true) == nil, "auto needs SSH")
renderers.reset_remote()
renderers.create("auto", true)
vim.env.SNACKS_SSH = "0"
renderers.create("auto", true) -- already applied: a manual toggle is kept
assert(vim.env.SNACKS_SSH == "0")
package.loaded["snacks"] = nil
vim.env.SNACKS_SSH = nil
package.loaded["snacks.image.terminal"] = nil
package.preload["snacks.image.terminal"] = function() error("missing") end
local remote, err = renderers.snacks_remote()
assert(remote == nil and err:find("not installed"))
print("renderer adapter tests passed")
