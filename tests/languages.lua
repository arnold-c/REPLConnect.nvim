-- nvim --headless -u NONE -l tests/languages.lua
-- Which session a command acts on: buffer filetype, then the pane or terminal
-- the buffer belongs to, then the only attached session, else ask.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local uv = vim.uv
local languages = require("replconnect.languages")
local fake = dofile("tests/support/fake_languages.lua")()

local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end
local function resolve(ctx) return { languages.resolve(ctx) } end

-- Pure resolution order.
eq(resolve({ filetype = "julia", owner = "r", attached = { "r" } }), { "julia", false })
eq(resolve({ filetype = "julia", attached = {} }), { "julia", false }) -- even when not attached
eq(resolve({ filetype = "", owner = "r", attached = { "julia", "r" } }), { "r", false })
eq(resolve({ filetype = "lua", attached = { "julia" } }), { "julia", false })
eq(resolve({ filetype = "lua", attached = { "julia", "r" } }), { nil, true })
eq(resolve({ attached = {} }), { nil, false })
eq(languages.label("julia"), "Julia")
eq(languages.label("r"), "R")
eq(languages.label("cobol"), "cobol")
eq(resolve({ filetype = "r", attached = { "julia" } }), { "r", false })

-- Discovery records: language defaults to Julia (older services) and is labelled.
local discover = require("replconnect.discover")
eq(discover.language({}), "julia")
eq(discover.language({ language = "r" }), "r")
assert(discover.label({ pid = 3, cwd = "/x", project = "", language = "julia" }):find("^Julia · "))
assert(discover.label({ pid = 3, cwd = "/x", language = "r" }):find("^R · "))

-- Picker previews use the session language's prompt.
local picker = require("replconnect.picker")
eq(select(1, picker.style({ language = "julia" })), "julia> ")
eq({ picker.style({ language = "cobol" }) }, { "> " })
eq(picker.transcript({ { input = "a\nb" } }, "> "), { "> a", "  b" })

-- Fake services for two languages.
local plugin = require("replconnect")
plugin.setup({ completion = false })

local function fake_service(language, pid)
	local path = vim.fn.tempname() .. ".sock"
	local server = uv.new_pipe(false)
	assert(server:bind(path))
	server:listen(8, function()
		local peer = uv.new_pipe(false)
		server:accept(peer)
		local buffer = ""
		peer:read_start(function(err, chunk)
			if err or not chunk then return end
			buffer = buffer .. chunk
			while buffer:find("\n", 1, true) do
				local nl = buffer:find("\n", 1, true)
				local req = vim.json.decode(buffer:sub(1, nl - 1))
				buffer = buffer:sub(nl + 1)
				local result = vim.empty_dict()
				if req.method == "initialize" then
					result = { protocol_version = 1, language = language, language_version = "1", pid = pid,
						capabilities = { "variables" } }
				elseif req.method == "list" then
					result = { variables = {}, length = 0, version = 0 }
				elseif req.method == "status" then
					result = { version = 0, busy = false }
				end
				peer:write(vim.json.encode({ jsonrpc = "2.0", id = req.id, result = result }) .. "\n")
			end
		end)
	end)
	return { pid = pid, socket = path, language = language }, server
end

local messages = {}
local original_notify = vim.notify
vim.notify = function(message) messages[#messages + 1] = message end
local function saw(text)
	for _, message in ipairs(messages) do
		if message:find(text, 1, true) then return true end
	end
	return false
end

-- Nothing attached: commands explain, naming the buffer's language.
local julia_buf = vim.api.nvim_create_buf(true, false)
vim.bo[julia_buf].filetype = "julia"
vim.api.nvim_set_current_buf(julia_buf)
plugin.open_vars()
assert(saw("no Julia session attached; run :REPLAttach"), vim.inspect(messages))

local julia_info, julia_server = fake_service("julia", 101)
local r_info, r_server = fake_service("r", 202)
plugin.attach(julia_info)
assert(vim.wait(2000, function() return plugin.client("julia") ~= nil end))

-- One session: every buffer uses it.
local scratch = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(scratch)
eq({ plugin.language() }, { "julia", false })
assert(plugin.client() == plugin.client("julia"))

plugin.attach(r_info)
assert(vim.wait(2000, function() return plugin.client("r") ~= nil end))
assert(plugin.client("julia") and plugin.client("julia").pid == 101, "one session per language")

-- Two sessions: the Julia buffer still means Julia; a neutral buffer is ambiguous.
eq({ plugin.language(julia_buf) }, { "julia", false })
eq({ plugin.language(scratch) }, { nil, true })
eq(plugin.client(), nil)

-- Ambiguous commands ask, offering only attached languages.
local offered, original_select = nil, vim.ui.select
vim.ui.select = function(items, opts, on_choice)
	offered = { items = items, labels = vim.tbl_map(opts.format_item, items) }
	on_choice("r")
end
plugin.open_vars()
eq(offered, { items = { "julia", "r" }, labels = { "Julia", "R" } })
local function pane_named(text)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(buf):find(text, 1, true) then return buf end
	end
end
local r_pane
assert(vim.wait(1000, function() r_pane = pane_named("r (pid 202) - Variables"); return r_pane ~= nil end))
vim.api.nvim_set_current_buf(r_pane)

-- The pane belongs to its session: commands from it need no question.
offered = nil
eq({ plugin.language(r_pane) }, { "r", false })
plugin.open_vars()
eq(offered, nil)

-- Declining the question does nothing.
vim.ui.select = function(_, _, on_choice) on_choice(nil) end
vim.api.nvim_set_current_buf(scratch)
plugin.detach()
assert(plugin.client("julia") and plugin.client("r"))

-- An explicit language wins, and detaching leaves the other session attached.
plugin.detach("r")
eq(plugin.client("r"), nil)
assert(plugin.client("julia"))
eq({ plugin.language(scratch) }, { "julia", false })
plugin.detach("julia")
vim.wait(100) -- let in-flight pane requests fail quietly

-- Completion: each filetype attaches to its own language's server, and
-- detaching one language leaves the other's completion running.
-- Registering after setup() works: languages come from separately loaded plugins.
plugin.setup({ completion = true })
languages.register({
	name = "fake", label = "Fake", filetypes = { "fakeft" }, prompt = "fake> ",
	trigger_characters = { "$" }, command = { "fake" }, plot_capture = false,
	plots_hint = "", stop_hint = "", build_cmd = function() return { "fake" } end,
})
eq(languages.names(), { "julia", "r", "fake" })
assert(not pcall(languages.register, { name = "broken" }), "incomplete adapters are rejected")
eq(languages.names(), { "julia", "r", "fake" })
local function servers(buf)
	local names = vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients({ bufnr = buf }))
	table.sort(names)
	return names
end
local fake_buf = vim.api.nvim_create_buf(true, false)
vim.bo[fake_buf].filetype = "fakeft"
local fake_info, fake_server = fake_service("fake", 303)
plugin.attach(julia_info)
assert(vim.wait(2000, function() return plugin.client("julia") ~= nil end))
assert(vim.wait(1000, function() return #servers(julia_buf) == 1 end))
eq(servers(julia_buf), { "replconnect-julia" })
eq(servers(fake_buf), {}) -- its language is not attached
plugin.attach(fake_info)
assert(vim.wait(2000, function() return #servers(fake_buf) == 1 end))
eq(servers(fake_buf), { "replconnect-fake" })
eq(servers(julia_buf), { "replconnect-julia" })
local fake_lsp = vim.lsp.get_clients({ name = "replconnect-fake" })[1]
eq(fake_lsp.server_capabilities.completionProvider.triggerCharacters, { "$" })
-- a buffer opened later attaches through FileType
local later = vim.api.nvim_create_buf(true, false)
vim.bo[later].filetype = "fakeft"
assert(vim.wait(1000, function() return #servers(later) == 1 end))
plugin.detach("fake")
assert(vim.wait(1000, function() return #vim.lsp.get_clients({ name = "replconnect-fake" }) == 0 end))
eq(servers(julia_buf), { "replconnect-julia" })
plugin.detach("julia")
vim.wait(100)
fake_server:close()
vim.fn.delete(fake_info.socket)

vim.ui.select = original_select
vim.notify = original_notify
julia_server:close()
r_server:close()
vim.fn.delete(julia_info.socket)
vim.fn.delete(r_info.socket)
print("language resolution tests passed")
