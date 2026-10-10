-- Unix-socket connector: newline-delimited JSON-RPC 2.0 (docs/protocol.md).
--
-- Implements the client interface used by the rest of the plugin:
--   client.request(method, params, on_result, on_error)
--   client.close()
--   client.info     result of `initialize`
-- All callbacks run on the main loop via vim.schedule.

local uv = vim.uv or vim.loop

local M = {}

M.PROTOCOL_VERSION = 1
M.DEFAULT_TIMEOUT_MS = 5000

local function decode(line)
	local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
	return ok and type(msg) == "table" and msg or nil
end

---@class replconnect.SocketClient
local Client = {}
Client.__index = Client

---Report a request error to the user (used when no `on_error` is given).
local function notify_error(method)
	return function(err)
		vim.notify(
			("replconnect: %s failed: %s"):format(method, tostring(err and err.message)),
			vim.log.levels.ERROR
		)
	end
end

---Send a request. `on_result(result)` or `on_error({code, message})` is called once,
---asynchronously. Without `on_error`, errors are shown with vim.notify.
---`timeout_ms` overrides the client's default timeout for this request.
---Returns the request id (the result is only available in the callback).
function Client:request(method, params, on_result, on_error, timeout_ms)
	on_error = on_error or notify_error(method)
	if self.closed then
		vim.schedule(function()
			on_error({ code = -32000, message = "connection closed" })
		end)
		return
	end
	self.next_id = self.next_id + 1
	local id = self.next_id
	local timer = uv.new_timer()
	local entry = { on_result = on_result, on_error = on_error, timer = timer }
	self.pending[id] = entry
	timer:start(timeout_ms or self.timeout_ms, 0, function()
		self:_settle(id, nil, { code = -32000, message = "request timed out: " .. method })
	end)
	local line = vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params }) .. "\n"
	self.pipe:write(line, function(err)
		if err then
			self:_settle(id, nil, { code = -32000, message = "write failed: " .. err })
		end
	end)
	return id
end

---Resolve one pending request (idempotent).
function Client:_settle(id, result, err)
	local entry = self.pending[id]
	if not entry then
		return
	end
	self.pending[id] = nil
	if not entry.timer:is_closing() then
		entry.timer:stop()
		entry.timer:close()
	end
	vim.schedule(function()
		if err then
			if entry.on_error then
				entry.on_error(err)
			end
		elseif entry.on_result then
			entry.on_result(result)
		end
	end)
end

---Register a notification handler; queued callbacks respect unsubscribe/close.
function Client:on(method, callback)
	local entry = { callback = callback, active = true }
	self.handlers[method] = self.handlers[method] or {}
	table.insert(self.handlers[method], entry)
	return function()
		entry.active = false
		local list = self.handlers[method] or {}
		for i, value in ipairs(list) do
			if value == entry then table.remove(list, i); break end
		end
	end
end

function Client:_on_data(chunk)
	self.buffer = self.buffer .. chunk
	while true do
		local nl = self.buffer:find("\n", 1, true)
		if not nl then
			break
		end
		local line = self.buffer:sub(1, nl - 1)
		self.buffer = self.buffer:sub(nl + 1)
		local msg = line ~= "" and decode(line) or nil
		if msg and msg.jsonrpc == "2.0" and msg.id == nil and type(msg.method) == "string" then
			for _, entry in ipairs(self.handlers[msg.method] or {}) do
				vim.schedule(function()
					if not self.closed and entry.active then
						local ok, err = pcall(entry.callback, msg.params)
						if not ok then vim.notify("replconnect notification: " .. tostring(err), vim.log.levels.ERROR) end
					end
				end)
			end
		elseif msg and msg.id ~= nil then
			if msg.error then
				self:_settle(msg.id, nil, msg.error)
			else
				self:_settle(msg.id, msg.result)
			end
		end
	end
end

---Close the connection, fail pending requests and fire `on_close` once.
function Client:close()
	if self.closed then
		return
	end
	self.closed = true
	self.handlers = {}
	-- Snapshot keys only: request entries contain non-copyable uv timers.
	for _, id in ipairs(vim.tbl_keys(self.pending)) do
		self:_settle(id, nil, { code = -32000, message = "connection closed" })
	end
	if not self.pipe:is_closing() then
		self.pipe:read_stop()
		self.pipe:close()
	end
	if self.on_close then
		vim.schedule(self.on_close)
	end
end

---Connect and run the `initialize` handshake.
---@param path string socket path
---@param opts? { timeout_ms?: integer, on_close?: fun(), client?: string, required_capabilities?: string[], ready_timeout_ms?: integer }
---@param callback fun(err: string|nil, client: replconnect.SocketClient|nil)
function M.connect(path, opts, callback)
	---What to check when a service never enables requested capabilities.
	local function startup_hint(language)
		local registered = require("replconnect.languages").get(language)
		return registered and registered.startup_hint or "check the REPL's startup errors and the loaded service version"
	end
	opts = opts or {}
	local pipe = uv.new_pipe(false)
	local client = setmetatable({
		pipe = pipe,
		pending = {},
		handlers = {},
		buffer = "",
		next_id = 0,
		closed = false,
		timeout_ms = opts.timeout_ms or M.DEFAULT_TIMEOUT_MS,
		on_close = opts.on_close,
	}, Client)

	pipe:connect(path, function(err)
		if err then
			pipe:close()
			client.closed = true
			return vim.schedule(function()
				callback("connect failed: " .. err)
			end)
		end
		pipe:read_start(function(read_err, chunk)
			if read_err or not chunk then
				client:close()
			else
				client:_on_data(chunk)
			end
		end)
		-- startup.jl can publish a server before the launcher's atreplinit hook
		-- enables plots. Do not attach with a permanently stale capability list.
		local started = uv.now()
		local finished = false
		local function fail(message)
			if finished then return end
			finished = true
			client:close()
			callback(message)
		end
		local initialize
		initialize = function()
			if finished then return end
			if client.closed then return fail("connection closed during initialize") end
			client:request("initialize",
				{ protocol_version = M.PROTOCOL_VERSION, client = opts.client or "replconnect.nvim" },
				function(info)
					if finished then return end
					if client.closed then return fail("connection closed during initialize") end
					if info.protocol_version ~= M.PROTOCOL_VERSION then
						return fail(("protocol mismatch: server speaks v%s, plugin v%d; update REPLConnect and the plugin together")
							:format(tostring(info.protocol_version), M.PROTOCOL_VERSION))
					end
					local missing = {}
					for _, capability in ipairs(opts.required_capabilities or {}) do
						if not vim.tbl_contains(info.capabilities or {}, capability) then missing[#missing + 1] = capability end
					end
					if #missing > 0 then
						if uv.now() - started >= (opts.ready_timeout_ms or client.timeout_ms) then
							return fail("service did not enable requested capabilities: " .. table.concat(missing, ", ")
								.. "; " .. (startup_hint(info.language)))
						end
						return vim.defer_fn(initialize, 100)
					end
					finished = true
					client.info = info
					client.language = info.language
					client.pid = info.pid
					callback(nil, client)
				end,
				function(e) fail("initialize failed: " .. tostring(e.message)) end)
		end
		initialize()
	end)
end

return M
