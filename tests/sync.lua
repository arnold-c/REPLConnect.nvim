-- Run from the repository root: nvim --headless -u NONE -l tests/sync.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local sync = require("replconnect.sync")

-- a burst of calls runs the function once, with the last arguments
local calls = {}
local call, close = sync.debounce(function(x) table.insert(calls, x) end, 20)
call(1)
call(2)
call(3)
assert(#calls == 0, "must not run synchronously")
assert(vim.wait(1000, function() return #calls == 1 end))
assert(calls[1] == 3)
vim.wait(80)
assert(#calls == 1, "a burst runs exactly once")

-- separate bursts run separately
call(4)
assert(vim.wait(1000, function() return #calls == 2 end))
assert(calls[2] == 4)

-- closing cancels a pending call and later calls are ignored
call(5)
close()
vim.wait(80)
assert(#calls == 2)
call(6)
vim.wait(80)
assert(#calls == 2)
close() -- idempotent

-- polling only fires while active, and stops
local ticks, active = 0, false
local stop = sync.poll(10, function() return active end, function() ticks = ticks + 1 end)
vim.wait(60)
assert(ticks == 0)
active = true
assert(vim.wait(1000, function() return ticks >= 2 end))
stop()
local seen = ticks
vim.wait(60)
assert(ticks == seen)
stop() -- idempotent

print("sync tests passed")
