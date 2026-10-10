-- Stand-in language adapters for the core tests, so they need no language plugin.
--   local fake = dofile("tests/support/fake_languages.lua")()   -- registers "julia" and "r"
-- Returns the registered adapters by name. The names mirror the real languages
-- only so tests can use realistic protocol fixtures; the launch details are fake.
local languages = require("replconnect.languages")

local function adapter(spec)
	return vim.tbl_extend("keep", spec, {
		trigger_characters = { "." },
		plot_capture = true,
		build_cmd = function(opts, extra)
			return vim.list_extend(vim.list_extend({}, opts.command), extra or {}), nil
		end,
	})
end

return function()
	local fake = {
		julia = adapter({
			name = "julia", label = "Julia", filetypes = { "julia" }, prompt = "julia> ",
			trigger_characters = { ".", "[", '"', ":" }, command = { "julia" },
			plots_hint = "run REPLConnect.capture_plots!(true) in the REPL",
			stop_hint = "run REPLConnect.stop() in the REPL",
		}),
		r = adapter({
			name = "r", label = "R", filetypes = { "r", "rmd", "rnoweb" }, prompt = "> ",
			trigger_characters = { "$", "@", ":", "[", '"', "(" }, command = { "arf" },
			plots_hint = "run replinspect::capture_plots(TRUE) in R",
			stop_hint = "run replinspect::shutdown() in R",
		}),
	}
	languages.register(fake.julia)
	languages.register(fake.r)
	return fake
end
