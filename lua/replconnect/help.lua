-- A centred floating window listing a pane's shortcuts.
local M = {}

---@alias replconnect.HelpEntry [string, string] key(s) and description

---Lines for `title` and aligned `entries`.
---@param title string
---@param entries replconnect.HelpEntry[]
---@return string[]
function M.lines(title, entries)
	local key_width = 0
	for _, entry in ipairs(entries) do key_width = math.max(key_width, vim.fn.strwidth(entry[1])) end
	local lines = { " " .. title, "" }
	for _, entry in ipairs(entries) do
		lines[#lines + 1] = (" %s%s   %s"):format(entry[1], (" "):rep(key_width - vim.fn.strwidth(entry[1])), entry[2])
	end
	return lines
end

---Open the help float; `q`, `<esc>`, `<cr>` or `g?` closes it.
---@param title string
---@param entries replconnect.HelpEntry[]
---@param on_close? fun() called once the float has closed
---@return integer win
function M.open(title, entries, on_close)
	local lines = M.lines(title, entries)
	local width = 0
	for _, l in ipairs(lines) do width = math.max(width, vim.fn.strwidth(l) + 1) end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = #lines,
		row = math.max(0, math.floor((vim.o.lines - #lines) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		style = "minimal",
		border = "rounded",
	})
	if on_close then
		vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true,
			callback = function() vim.schedule(on_close) end })
	end
	for _, key in ipairs({ "q", "<esc>", "<cr>", "g?" }) do
		vim.keymap.set("n", key, function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, silent = true })
	end
	return win
end

return M
