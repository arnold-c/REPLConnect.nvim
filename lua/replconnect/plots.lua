-- Language-neutral static artifact history. Only metadata is kept here.
local Buf = require("replconnect.buf")
local Plots = setmetatable({}, { __index = Buf })
Plots.__index = Plots

local function valid(record)
	return type(record) == "table" and type(record.id) == "number" and record.id > 0
		and record.id % 1 == 0 and (record.mime == "image/png" or record.mime == "image/svg+xml")
		and type(record.path) == "string" and record.path:sub(1, 1) == "/"
		and not record.path:find("[%z\r\n]")
end

function Plots.supported(client)
	return vim.tbl_contains(client.info and client.info.capabilities or client.capabilities or {}, "plots")
end

---open_window (see `Buf.open`) is called for every open, including automatic opening.
---@param open_window? replconnect.WindowOpener
function Plots.init(client, opts, open_window, may_auto_open)
	if not Plots.supported(client) then return nil end
	local self = Buf.init(Plots, { name = "replconnect://plots/" .. client.language })
	self.client, self.records, self.follow, self.alive = client, {}, true, true
	self.dismissed = {} -- ids removed from history; refresh must not resurrect them
	self.opts = opts or require("replconnect.config").options.plots
	self.open_window = open_window
	self.may_auto_open = may_auto_open
	self.renderer = require("replconnect.renderers").create(self.opts.renderer, self.opts.remote)
	vim.bo[self.buf].filetype = "replconnect-plots"
	vim.bo[self.buf].bufhidden = "hide"
	local actions = {
		close = function() self:hide() end,
		next = function() self:move(1) end,
		previous = function() self:move(-1) end,
		refresh = function() self:refresh() end,
		follow = function() self:latest() end,
		external = function() self:external() end,
		save = function() self:save() end,
		delete = function() self:delete() end,
		clear = function() self:clear() end,
		fullscreen = function() self:toggle_fullscreen() end,
	}
	for action, keys in pairs(self.opts.keymaps or {}) do
		if keys and actions[action] then
			for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
				vim.keymap.set("n", key, actions[action], { buffer = self.buf, silent = true })
			end
		end
	end
	self.group = vim.api.nvim_create_augroup("replconnect.plots." .. self.buf, { clear = true })
	vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, { group = self.group, buffer = self.buf,
		callback = function() self:clear_image() end })
	-- WinResized also fires for unrelated floats (completion menus resize on
	-- every keystroke); redrawing then would make the image flicker.
	vim.api.nvim_create_autocmd("WinResized", { group = self.group,
		callback = function() self:resized(vim.v.event.windows) end })
	vim.api.nvim_create_autocmd("VimResized", { group = self.group,
		callback = function()
			if self:fullscreen_win() then vim.api.nvim_win_set_config(self.float, self:float_config()) end
			if self:winid() then self:draw() end
		end })
	-- Install before subscribing; merge the snapshot with already delivered events.
	self.unsubscribe = client:on("display", function(record)
		if not self.alive or self.client.closed then return end
		self:merge({ record })
		self:auto_open()
	end)
	client:request("plots_subscribe", {}, function(result)
		if self.alive and not client.closed then
			self:merge(result.plots or {})
			self:auto_open()
		end
	end)
	self:draw()
	return self
end

function Plots:merge(records, replace)
	local by_id = {}
	if not replace then
		for _, record in ipairs(self.records) do
			-- Bound metadata too: discard pruned artifacts, but retain a missing
			-- selection until refresh so browsing gets an actionable message.
			if record.id == self.selected or vim.fn.filereadable(record.path) == 1 then by_id[record.id] = record end
		end
	end
	for _, record in ipairs(records) do if valid(record) and not self.dismissed[record.id] then by_id[record.id] = record end end
	self.records = vim.tbl_values(by_id)
	table.sort(self.records, function(a, b) return a.id < b.id end)
	if self.follow or not by_id[self.selected] then
		self.selected = self.records[#self.records] and self.records[#self.records].id or nil
	end
	self:draw()
end

function Plots:current()
	for i, record in ipairs(self.records) do if record.id == self.selected then return record, i end end
end

function Plots:clear_image()
	pcall(self.renderer.clear)
end

function Plots:draw()
	if not self.alive or not self:valid() then return end
	self:clear_image()
	local record, index = self:current()
	local lines = { ("Plots · %s · %s"):format(self.client.language, self.follow and "following latest" or "browsing"),
		"Ctrl-p / Ctrl-n browse · Ctrl-e fullscreen · f follow · r refresh · o open · s save · <leader>d delete · X clear all · q close" }
	local exists = record and vim.fn.filereadable(record.path) == 1
	if not record then
		lines[#lines + 1] = "No plots yet. Display a plot in the REPL (capture must be enabled)."
	elseif not exists then
		lines[#lines + 1] = "Plot file expired or disappeared. Press r to refresh history."
	else
		lines[#lines + 1] = ("%d/%d · #%d · %s"):format(index, #self.records, record.id, record.mime)
		lines[#lines + 1] = record.path
		lines[#lines + 1] = "Press o to open externally; s saves a permanent copy."
		if self.renderer.reason then lines[#lines + 1] = "No image renderer: " .. self.renderer.reason end
		lines[#lines + 1] = ""
	end
	vim.bo[self.buf].modifiable = true
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
	vim.bo[self.buf].modifiable = false
	local win = self:winid()
	if exists and win then
		local ok, err = pcall(self.renderer.render, record, { buf = self.buf, win = win })
		if not ok then
			self:clear_image()
			vim.notify("replconnect: image renderer unavailable; press o to open externally: " .. tostring(err), vim.log.levels.WARN)
		end
	end
end

---Redraw only when the plot window is among the resized `windows`.
---@param windows? integer[]
function Plots:resized(windows)
	local win = self:winid()
	if win and vim.tbl_contains(windows or {}, win) then self:draw() end
end

---The fullscreen float, if open.
---@return integer?
function Plots:fullscreen_win()
	if self.float and vim.api.nvim_win_is_valid(self.float) then return self.float end
	self.float = nil
end

---Prefer the fullscreen float so the image is drawn there while it is open.
function Plots:winid()
	return self:fullscreen_win() or Buf.winid(self)
end

function Plots:float_config()
	local height = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
	return { relative = "editor", row = 0, col = 0, width = vim.o.columns,
		height = math.max(1, height), style = "minimal", border = "none" }
end

---Show the plot in a floating window covering the editor, or close it.
function Plots:toggle_fullscreen()
	if self:fullscreen_win() then
		pcall(vim.api.nvim_win_close, self.float, true)
		return
	end
	local previous = vim.api.nvim_get_current_win()
	self.float = vim.api.nvim_open_win(self.buf, true, self:float_config())
	local float = self.float
	vim.api.nvim_create_autocmd("WinClosed", { group = self.group, pattern = tostring(float), once = true,
		callback = function()
			if self.float == float then self.float = nil end
			vim.schedule(function()
				if vim.api.nvim_win_is_valid(previous) then pcall(vim.api.nvim_set_current_win, previous) end
				self:draw()
			end)
		end })
	self:draw()
end

function Plots:move(delta)
	local _, index = self:current()
	if not index then return end
	self.follow = false
	self.selected = self.records[math.max(1, math.min(#self.records, index + delta))].id
	self:draw()
end

---Remove the plot being viewed from the history.
function Plots:delete()
	local record, index = self:current()
	if not record then return end
	self.dismissed[record.id] = true
	table.remove(self.records, index)
	local neighbour = self.records[math.min(index, #self.records)]
	self.selected = neighbour and neighbour.id or nil
	self:draw()
end

---Remove every plot from the history.
function Plots:clear()
	for _, record in ipairs(self.records) do self.dismissed[record.id] = true end
	self.records, self.selected = {}, nil
	self:draw()
end

function Plots:latest()
	self.follow = true
	self.selected = self.records[#self.records] and self.records[#self.records].id or nil
	self:draw()
end

function Plots:refresh()
	-- Events delivered after this request belong after its snapshot, even when
	-- a fake/asynchronous client delays the response callback.
	self.refresh_generation = (self.refresh_generation or 0) + 1
	local generation = self.refresh_generation
	local newest = self.records[#self.records] and self.records[#self.records].id or 0
	self.client:request("plots", {}, function(result)
		if not self.alive or self.client.closed or generation ~= self.refresh_generation then return end
		local records = vim.deepcopy(result.plots or {})
		for _, record in ipairs(self.records) do if record.id > newest then records[#records + 1] = record end end
		self:merge(records, true)
	end)
end

function Plots:auto_open()
	if self.opts.auto_open and #self.records > 0 and not self:winid()
		and (not self.may_auto_open or self.may_auto_open()) then
		self:open(false, false)
	end
end

function Plots:open(focus, refresh)
	local previous = vim.api.nvim_get_current_win()
	Buf.open(self, self.open_window)
	if focus == false and vim.api.nvim_win_is_valid(previous) then vim.api.nvim_set_current_win(previous) end
	self:draw()
	if refresh ~= false then self:refresh() end
end

function Plots:hide()
	self:clear_image()
	for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do pcall(vim.api.nvim_win_close, win, true) end
end

function Plots:file()
	local record = self:current()
	if record and vim.fn.filereadable(record.path) == 1 then return record end
	vim.notify("replconnect: no plot file; refresh with r", vim.log.levels.WARN)
end

function Plots:external()
	local record = self:file()
	if record then vim.ui.open(record.path) end
end

function Plots:save(destination)
	local record = self:file()
	if not record then return end
	local function copy(path)
		if not path or path == "" then return end
		path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
		-- Saving inside the producer's temporary directory would not preserve it.
		local source_dir = (vim.uv.fs_realpath(vim.fn.fnamemodify(record.path, ":h")) or "") .. "/"
		local parent = vim.uv.fs_realpath(vim.fn.fnamemodify(path, ":h"))
		if parent and (parent .. "/"):sub(1, #source_dir) == source_dir then
			return vim.notify("replconnect: save outside the temporary plot directory", vim.log.levels.WARN)
		end
		local ok, err = vim.uv.fs_copyfile(record.path, path, { excl = true })
		vim.notify(ok and ("Saved plot to " .. path) or ("Could not save plot: " .. tostring(err)),
			ok and vim.log.levels.INFO or vim.log.levels.ERROR)
	end
	if destination then copy(destination) else
		vim.ui.input({ prompt = "Save plot as: ", default = "plot-" .. record.id .. (record.mime == "image/png" and ".png" or ".svg"), completion = "file" }, copy)
	end
end

function Plots:wipe()
	self.alive = false
	if self.unsubscribe then self.unsubscribe(); self.unsubscribe = nil end
	self:clear_image()
	vim.api.nvim_del_augroup_by_id(self.group)
	Buf.wipe(self)
end
return Plots
