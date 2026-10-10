# REPLConnect quickstart (development)

Julia side, with REPLConnect installed (`]dev /path/to/REPLConnect.jl` into your default environment), in `~/.julia/config/startup.jl`:

```julia
if isinteractive()
    using REPLConnect
    REPLConnect.start()                 # server only; safe to call repeatedly
    # REPLConnect.capture_plots!(true)  # optional: capture plots from the start
end
```

Top level is simplest: the module exists before anything calls it, so no `@eval` or `Base.invokelatest` is needed, and REPLConnect hooks into the REPL that starts afterwards.
Code inside an `atreplinit` hook instead runs in the world in which the hook was defined, so a module loaded there must be called through `Base.invokelatest`.
Without installing the package, include the source once instead of `using`:
`isdefined(Main, :REPLConnect) || include("/path/to/REPLConnect.jl/src/REPLConnect.jl")`.

`start()` only runs the server.
Behaviour is configured separately, in `startup.jl` or at the prompt at any time:

```julia
REPLConnect.capture_plots!(true; limit = 50)  # plot capture (off by default)
REPLConnect.capturing_plots()                 # is it on?
REPLConnect.record_history!(false)            # input history for the picker (on by default)
REPLConnect.stop()                            # stop serving; :REPLStop does this from Neovim
```

`:REPLStart` runs its own REPL hook after everything in `startup.jl`, so with `repl.capture_plots = true` it turns plot capture on in the module loaded here, even if `startup.jl` turned it off.
Without REPLConnect in `startup.jl` it loads an installed REPLConnect package (`using REPLConnect`) when Julia can find one, and otherwise includes this plugin checkout's source.
Keep an installed package and the plugin at the same version.

This listens on `/tmp/replconnect-<uid>/<pid>.sock` and writes `<pid>.json` next to it.
Set `REPLCONNECT_DIR` to use another directory; it must then be set for both Julia and Neovim.
`TMPDIR`/`XDG_RUNTIME_DIR` are ignored because the two processes often see different values (e.g. macOS GUI apps, tmux).

Neovim side:

With lazy.nvim, use a local plugin spec.
lazy.nvim resets the runtimepath, so a manual `runtimepath:append` before `lazy.setup()` is dropped:

```lua
{
  dir = "/path/to/REPLConnect.nvim",
  name = "replconnect",
  opts = {
    -- poll_interval_ms = 1000,   -- refresh a visible pane on a timer (0 = off, default)
    -- update_while_busy = false, -- see "Performance" in the README
    -- completion = true,
    -- exclude = { "ans" },
  },
  config = function(_, opts) require("replconnect").setup(opts) end,
}
```

Without a plugin manager:

```lua
vim.opt.runtimepath:append("/path/to/REPLConnect.nvim")
require("replconnect").setup()
```

Commands:

- `:REPLStart [vertical|horizontal] [julia|r] [REPL switches]` opens a terminal split running the REPL for the current buffer's language (asking when no buffer, pane or single attached session decides) and attaches as soon as its server is up.
  The direction overrides `repl.split` for this start; Neovim's modifiers work too (`:horizontal REPLStart`).
  Switches are passed to the REPL, for example `:REPLStart horizontal --project=.`.
  For Julia it loads REPLConnect itself, so `startup.jl` is not required; if `startup.jl` already loads it, nothing is loaded twice.
  For R it runs `arf` (`repl.r.command`) with `R_PROFILE_USER` pointing at a generated profile that first runs your usual profile (`$R_PROFILE_USER`, `./.Rprofile` or `~/.Rprofile`) and then `replconnect::start()` if the replconnect R package is installed.
  Settings under `repl` apply to every language; `repl.julia` and `repl.r` override them and set each `command` (a top-level `repl.command` is ignored).
  Each language comes from its own optional extension plugin, not a default ([arnold-c/REPLConnect.jl](https://github.com/arnold-c/REPLConnect.jl), [arnold-c/REPLConnect.R](https://github.com/arnold-c/REPLConnect.R); see the README).
  `:REPLStart` only offers the languages whose plugin is installed.
  REPLs started this way are stopped when Neovim exits (SIGTERM, then SIGKILL after 3 seconds if needed), so they never outlive the editor; REPLs you started yourself and attached to are left running.
- `:REPLStop [pid|language]` opens a picker over every running REPL (attached or not), with the current buffer's attached REPL first, and asks for confirmation before stopping its server.
  With [snacks.nvim](https://github.com/folke/snacks.nvim), `<Tab>` selects several REPLs to stop at once, after a single confirmation.
  An attached REPL is detached; the REPL itself keeps running.
  `:REPLStop!` also closes a REPL running in a Neovim terminal, for example after its window was closed and the REPL is no longer visible.
  A pid or language narrows the picker to matching sessions.
  Each entry says where the REPL runs: started by this Neovim, in a terminal of this Neovim, a child of this Neovim that is not a terminal (such as a language server), in another Neovim, orphaned (its parent exited), or external.
  A REPL that accepts the connection but never answers (typically left over from a Neovim that did not exit cleanly) is offered to be killed instead, after a second confirmation that shows the process's command line: SIGTERM, then SIGKILL if it is still running a few seconds later.
  Check that command: a non-interactive process that started the service (for example R's `languageserver`) never answers either, and killing it ends your language server.
- `:REPLAttach [pid]`, `:REPLDetach` (attach to a REPL you started yourself).
  With several REPLs running, `:REPLAttach` opens a picker; if [snacks.nvim](https://github.com/folke/snacks.nvim) is installed, it previews the last few inputs of the highlighted REPL (otherwise it falls back to `vim.ui.select`).
  The last 10 inputs are kept for this; turn it off at any time with `REPLConnect.record_history!(false)`.
- `:REPLVariables` toggles the variables pane.
  It refreshes when you enter it, on terminal focus and with `r`.
  `g?` lists the pane's keys.
- `:REPLPlots` toggles static plot history.
  Enable Julia capture with `REPLConnect.capture_plots!(true)`; see [plots.md](plots.md) for renderers, keymaps and saving.
- `:REPLVariableViewer [name[.field]]` opens a grid for a table or array.
  In the pane, `v` opens the variable under the cursor.

One REPL is attached per language.
Commands act on the language of the current buffer: its filetype (a Julia file means the Julia REPL), else the pane or REPL terminal it belongs to, else the only attached REPL; if several are attached and none of these applies, you are asked which.
`:REPLVariables`, `:REPLPlots` and `:REPLDetach` also take the language explicitly, e.g. `:REPLVariables julia`.

The pane's window bar shows the session and its state:

- `evaluating`: the REPL is running code, but still answers (code that yields).
- `REPL busy; showing last known values`: the REPL did not answer within a second, which is what a long computation looks like.
  The pane keeps the last values and catches up once the REPL is idle.
- `REPL exited; :REPLAttach to reconnect`: the connection is gone (the REPL was closed or restarted).
  Attach to the new session; the old pane is replaced.
  A REPL in a Neovim terminal that keeps running (arf's `:restart`/`:switch`, or starting REPLConnect again) is reattached automatically once its new server is up.

Syncing is debounced (50 ms) and asks the REPL for `status` first, so an unchanged session costs one tiny request.
Terminal focus events trigger it on most terminals; in tmux set `focus-events on`.
Where focus events are missing, set `poll_interval_ms` to refresh a visible pane on a timer.

If the REPL runs in a Neovim `:terminal` buffer (found by walking up the process tree from the REPL's pid to the terminal's job), the pane also syncs whenever you leave that buffer: back to normal mode with `<C-\><C-n>`, or to another window.
`:REPLAttach` says when it found the terminal, and lists such sessions first in the picker.
Nothing else depends on this.

While the REPL is evaluating, the pane shows `evaluating` and does not scan your variables; it catches up once the REPL is idle.
Set `update_while_busy = true` to fetch changes during an evaluation too.
That can slow code that yields.

**Do not keep the pane open during performance-critical computations that yield** (`sleep`, I/O, `Channel`, `@async`): the REPL answers Neovim's requests at each yield, on the computation's thread.
Close the pane or `:REPLDetach` for timing-sensitive runs.
Code that never yields is not affected.
See the Performance section of the README.

Change detection never calls `show` on your values: it compares identity, type and size.
Reassignments, `push!` and other size changes, and added table columns or rows show up automatically.
In-place changes that keep the size (`x[1] = 5`, `df[1, :a] = 1`) show up on the next reassignment or when you press `r`.

`:REPLStart` is configured under `repl`:

```lua
opts = {
  repl = {
    split = "vertical",     -- or "horizontal"
    size = nil,             -- width (vertical) or height (horizontal); nil = half
    command = { "julia" },  -- e.g. { "julia", "+1.12" } or a full path
    enter = true,           -- start in terminal mode, ready to type
    capture_plots = false,  -- true enables static plot capture in this REPL
    plot_limit = 50,        -- retained files when capture is newly enabled
  },
}
```

The REPL runs in an unlisted buffer, so it does not appear in buffer lists or bufferline tabs.
It closes after a clean `exit()`, and stays open if Julia fails so the error can be read.

### Pane layouts

Use string layouts directly in `opts.layout`.
These are equivalent to the defaults (no exclusive alternatives):

```lua
layout = {
  horizontal = [[ (editor | vars | plots | view) / repl ]],
  vertical = [[ editor | (vars / plots / view / repl) ]],
  external = [[ editor | (vars / plots / view) @ 60 ]],
},
```

`|` means side by side, `/` means stacked, and `\` means alternatives sharing one region **in that layout only**.
Parentheses group regions; `@ 35%` sizes a region as a percentage of the width (in a row) or height (in a stack) of the region that contains it.
`@ 60` means character cells.
For example:

```lua
layout = {
  horizontal = [[
    (editor @ 60% / repl) | (((plots \ view) @ 30%) / vars) @ 35%
  ]],
  vertical = [[ repl @ 30% | editor | ((plots \ view) / vars) @ 25% ]],
  external = [[ editor | ((plots \ view) / vars) @ 40% ]],
},
```

The REPL split selects `horizontal`/`vertical`; `external` is used when no REPL terminal is visible in the tab.
`editor` represents your other windows and must appear exactly once.
Hidden panes collapse out of the layout.
Explicit sizes take precedence over remembered sizes; unsized siblings get the remainder.
Percentages are shares of the enclosing region (the screen for the outermost one), so the sized panes of a group should total 100% or leave one unsized.
Sizes may be constrained by Neovim's window minimums and separators.

The reusable data viewer (`view`) changes variable without opening a second pane.
`plots \ view` lets it replace plots; closing the active pane restores the one it replaced.
Background plot auto-open does not evict an exclusive viewer.

See [README: Pane layouts](../README.md#pane-layouts) for copyable recipes, precedence rules and ASCII diagrams.
Window moves need Neovim 0.10 or later.

### Vim keybindings in the REPL

Packages that add modal editing to the REPL, such as VimBindings.jl, fight with Neovim's own modes inside a terminal buffer.
Neovim sets `$NVIM` for every process it starts, so skip them there in `startup.jl`:

```julia
if isinteractive() && !haskey(ENV, "NVIM")
    using VimBindings
end
```

This covers `:REPLStart` and REPLs started with `:terminal`; REPLs in other terminals keep their bindings.

If attaching takes longer than 90 s (a first start can precompile), it gives up with a warning; run `:REPLAttach` once the prompt appears.

Options go to `setup{ exclude = {...}, poll_interval_ms = 0, update_while_busy = false, repl = {...}, layout = {...}, viewer = { keymaps = {...} } }`.

## Completion

While a REPL is attached, buffers of its language get an in-process LSP server named after it (`replconnect-julia`).
Each filetype completes from its own language's REPL, so Julia and R buffers in one project use their own sessions.
It completes from the live session: variables you defined at the prompt, properties of runtime values, and table column names inside `df[!, :`, `df[:, :` and `df["`.
Items are labelled `runtime`.

blink.cmp's default LSP source picks it up with no extra configuration, and it runs next to other servers (fatou, JETLS), whose items are merged.
Set `setup{ completion = false }` to turn it off.

The attached client is available through `require("replconnect").client(language)` and `require("replconnect").on_attach(fn)`.
