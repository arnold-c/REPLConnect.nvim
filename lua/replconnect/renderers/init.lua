-- Optional image plugins own graphics protocols, terminal detection and fitting.
local M = {}
local function noop() end

local function remote()
	return vim.env.SSH_CONNECTION ~= nil or vim.env.SSH_CLIENT ~= nil or vim.env.SSH_TTY ~= nil
end

local function external(reason)
	return { name = "external", reason = reason, render = noop, clear = noop }
end

---@return table? adapter, string? reason
local function snacks()
	local ok, image = pcall(require, "snacks.image")
	if not ok then return nil, "snacks.nvim not installed" end
	local supported, available = pcall(image.supports_terminal)
	if not supported or not available then
		return nil, "Snacks did not detect a kitty-graphics terminal" .. (remote()
			and " over SSH (set SNACKS_KITTY=1, SNACKS_GHOSTTY=1 or SNACKS_WEZTERM=1 on the remote)" or "")
	end
	local placement
	return {
		name = "Snacks",
		clear = function()
			if placement then placement:close(); placement = nil end
		end,
		render = function(record, ctx)
			placement = image.placement.new(ctx.buf, record.path, { pos = { 6, 0 }, inline = true, auto_resize = true,
				max_width = vim.api.nvim_win_get_width(ctx.win), max_height = math.max(1, vim.api.nvim_win_get_height(ctx.win) - 5) })
		end,
	}
end

---Switch Snacks between sending file paths (local terminal) and streaming
---image bytes (remote terminal, e.g. over SSH); toggles when `on` is nil.
---Relies on Snacks internals: resetting its cached environment makes it
---re-read `SNACKS_SSH` ("0" overrides an earlier SSH detection), and
---clearing its image cache resends images to the current terminal.
---@param on? boolean
---@return boolean? remote, string? err
function M.snacks_remote(on)
	local ok, terminal = pcall(require, "snacks.image.terminal")
	if not ok then return nil, "snacks.nvim not installed" end
	if on == nil then on = not terminal.env().remote end
	vim.env.SNACKS_SSH = on and "1" or "0"
	terminal._env = nil
	require("snacks.image.image").clear()
	return terminal.env().remote == true
end

---@return table? adapter, string? reason
local function image_nvim()
	local ok, image = pcall(require, "image")
	if not ok then return nil, "image.nvim not installed" end
	local instance
	return {
		name = "image.nvim",
		clear = function()
			if instance then instance:clear(); instance = nil end
		end,
		render = function(record, ctx)
			instance = image.from_file(record.path, { buffer = ctx.buf, window = ctx.win, x = 0, y = 3,
				width = vim.api.nvim_win_get_width(ctx.win), height = math.max(1, vim.api.nvim_win_get_height(ctx.win) - 3) })
			if instance then instance:render() end
		end,
	}
end

---Try candidates in order; an unavailable renderer explains why in `reason`.
local function first(...)
	local reasons = {}
	for _, candidate in ipairs({ ... }) do
		local adapter, reason = candidate()
		if adapter then return adapter end
		reasons[#reasons + 1] = reason
	end
	return external(table.concat(reasons, "; "))
end

---Apply the `plots.remote` setting once per session, before a Snacks renderer
---is chosen. `true`/`false` always set streaming on/off. `"auto"` streams only
---when Snacks is already loaded and Neovim runs over SSH, else changes nothing.
---`nil` leaves Snacks alone. Later `:REPLPlotsRemote` toggles are kept.
---@param setting? boolean | "auto"
local applied = false
local function apply_remote(setting)
	if applied or setting == nil then return end
	local on = setting
	if setting == "auto" then
		if not (package.loaded["snacks"] and remote()) then return end
		on = true
	end
	applied = true
	M.snacks_remote(on)
end

---Forget that `plots.remote` was applied (for tests and config changes).
function M.reset_remote() applied = false end

---@param choice string | table
---@param remote_setting? boolean | "auto" the `plots.remote` option
function M.create(choice, remote_setting)
	if type(choice) == "table" then return choice end
	if choice == "auto" or choice == "snacks" then apply_remote(remote_setting) end
	if choice == "snacks" then return first(snacks) end
	if choice == "image.nvim" then return first(image_nvim) end
	if choice == "external" then return external() end
	return first(snacks, image_nvim)
end
return M
