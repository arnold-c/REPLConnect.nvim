-- Run from the repository root: nvim --headless -u NONE -l tests/lsp.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local lsp = require("replconnect.lsp")

-- positions <-> byte offsets (multi-line, multi-byte)
local lines = { "αβ = 1", "x = al", "" }
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end
eq(lsp.position_to_offset(lines, { line = 0, character = 0 }), 0)
eq(lsp.position_to_offset(lines, { line = 1, character = 6 }), #"αβ = 1" + 1 + 6)
eq(lsp.position_to_offset(lines, { line = 1, character = 99 }), #"αβ = 1" + 1 + 6) -- clamped
for _, offset in ipairs({ 0, 4, #"αβ = 1", #"αβ = 1" + 1, #"αβ = 1" + 1 + 6, #"αβ = 1" + 1 + 6 + 1 }) do
	local pos = lsp.offset_to_position(lines, offset)
	eq(lsp.position_to_offset(lines, pos), offset)
end
eq(lsp.offset_to_position(lines, #"αβ = 1" + 1), { line = 1, character = 0 })

-- completion list
local list = lsp.to_completion_list(lines, {
	start = #"αβ = 1" + 1 + 4, stop = #"αβ = 1" + 1 + 6,
	items = { { label = "alpha", kind = 6, detail = "Int64" }, { label = "also", kind = 3 } },
})
assert(list.isIncomplete == true and #list.items == 2)
local first = list.items[1]
eq(first.label, "alpha")
eq(first.kind, 6)
eq(first.detail, "Int64")
eq(first.labelDetails.description, "runtime")
eq(first.textEdit.newText, "alpha")
eq(first.textEdit.range, { start = { line = 1, character = 4 }, ["end"] = { line = 1, character = 6 } })
assert(list.items[1].sortText < list.items[2].sortText)

-- the in-process server
local requests = {}
local fake_client = {
	closed = false,
	request = function(_, method, params, on_result)
		requests[#requests + 1] = { method = method, params = params }
		on_result({ start = params.cursor - 2, stop = params.cursor, items = { { label = "alpha", kind = 6 } } })
	end,
}
local client = fake_client
local exits = {}
local server = lsp.cmd(function() return client end, function() return { "x = al" } end, { ".", "$" })({
	on_exit = function(code, signal) exits[#exits + 1] = { code, signal } end,
})

local function call(method, params)
	local out
	local ok, id = server.request(method, params, function(err, result) out = { err = err, result = result } end)
	assert(ok and type(id) == "number")
	return out
end

local init = call("initialize", {})
eq(init.result.capabilities.positionEncoding, "utf-8")
eq(init.result.capabilities.completionProvider.triggerCharacters, { ".", "$" })
eq(lsp.server_name("julia"), "replconnect-julia")
eq(lsp.cmd(function() end)({}).request("initialize", {}, function(_, result)
	eq(result.capabilities.completionProvider.triggerCharacters, {})
end), true)

local reply = call("textDocument/completion", {
	textDocument = { uri = "file:///x.jl" }, position = { line = 0, character = 6 },
})
eq(requests[1].method, "complete")
eq(requests[1].params, { code = "x = al", cursor = 6 })
eq(reply.result.items[1].textEdit.range, { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 6 } })

-- not attached / closed: empty, incomplete list and no error
client = nil
reply = call("textDocument/completion", {
	textDocument = { uri = "file:///x.jl" }, position = { line = 0, character = 6 },
})
assert(reply.err == nil and #reply.result.items == 0 and reply.result.isIncomplete)

-- errors from the REPL never surface as completion errors
client = {
	closed = false,
	request = function(_, _, _, _, on_error) on_error({ code = -32603, message = "boom" }) end,
}
reply = call("textDocument/completion", {
	textDocument = { uri = "file:///x.jl" }, position = { line = 0, character = 6 },
})
assert(reply.err == nil and #reply.result.items == 0)

assert(call("bogus", {}).err.code == -32601)
assert(server.notify("initialized", {}) == true)
assert(not server.is_closing())
server.notify("exit")
assert(server.is_closing())
-- Neovim is told the server exited (once), so it drops the client
server.terminate()
assert(vim.wait(500, function() return #exits == 1 end))
vim.wait(50)
eq(exits, { { 0, 0 } })

print("lsp tests passed")
