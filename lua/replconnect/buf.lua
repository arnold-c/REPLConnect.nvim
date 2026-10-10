-- A small scratch-buffer helper for the variables pane.
--
-- Subclasses call `Buf.init(Class, { name = ... })` and get an object with
-- `buf` (buffer handle) and `ns` (highlight namespace); `Buf.open(self)`
-- shows the buffer (where the caller's opener puts it, see
-- `replconnect.layout`, else in a right-hand split), or focuses the window
-- that already shows it.

---@class replconnect.Buf
---@field buf integer
---@field ns integer
---@field name string
local Buf = {}
Buf.__index = Buf

local WIDTH = 60

---Create the scratch buffer and an instance of `class` (a table whose
---metatable chain reaches `Buf`).
---@generic T
---@param class T
---@param opts { name: string }
---@return T
function Buf.init(class, opts)
	local self = setmetatable({ name = opts.name }, class)
	self.buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, self.buf, opts.name)
	self.ns = vim.api.nvim_create_namespace("replconnect." .. opts.name)
	return self
end

---The window showing this buffer in the current tab, if any.
---@return integer?
function Buf:winid()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(win) == self.buf then
			return win
		end
	end
end

---Whether the underlying buffer still exists.
---@return boolean
function Buf:valid()
	return vim.api.nvim_buf_is_valid(self.buf)
end

---Opens a window for a pane's buffer without focusing it, and returns it.
---@alias replconnect.WindowOpener fun(): integer

---Show the buffer (or focus its window) and return the window.
---@param open_window? replconnect.WindowOpener default: a full-height right-hand column
---@return integer win
function Buf:open(open_window)
	local win = self:winid()
	if win then
		vim.api.nvim_set_current_win(win)
		return win
	end
	win = open_window and open_window()
		or vim.api.nvim_open_win(self.buf, false, { split = "right", win = -1, width = WIDTH })
	vim.api.nvim_set_current_win(win)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	return win
end

---Close the window and wipe the buffer.
function Buf:wipe()
	if self:valid() then
		vim.api.nvim_buf_delete(self.buf, { force = true })
	end
end

return Buf
