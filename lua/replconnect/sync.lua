-- Timing helpers for keeping the variables pane in step with the REPL.
--
-- Triggers (pane enter, terminal focus, ...) can fire in bursts; `debounce`
-- turns a burst into one call. `poll` is the optional fallback for setups
-- without focus events.

local uv = vim.uv or vim.loop

local M = {}

M.DEBOUNCE_MS = 50

---Return `call(...)`, which runs `fn` once, `ms` after the last call (on the main loop),
---and `close()`, which cancels a pending call and frees the timer.
---@param fn fun(...)
---@param ms? integer
---@return fun(...) call
---@return fun() close
function M.debounce(fn, ms)
	ms = ms or M.DEBOUNCE_MS
	local timer = uv.new_timer()
	local call = function(...)
		if timer:is_closing() then
			return
		end
		local args = vim.F.pack_len(...)
		timer:stop()
		timer:start(
			ms,
			0,
			vim.schedule_wrap(function()
				fn(vim.F.unpack_len(args))
			end)
		)
	end
	local close = function()
		if not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
	return call, close
end

---Call `fn` every `ms` while `active()` is true. Returns a `stop` function.
---@param ms integer
---@param active fun(): boolean
---@param fn fun()
---@return fun() stop
function M.poll(ms, active, fn)
	local timer = uv.new_timer()
	timer:start(
		ms,
		ms,
		vim.schedule_wrap(function()
			if active() then
				fn()
			end
		end)
	)
	return function()
		if not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
end

return M
