# Static plots from a plain REPL

Plot capture is **opt-in**, independent of the variables pane:

```julia
REPLConnect.start()                          # server only; safe to repeat
REPLConnect.capture_plots!(true; limit = 50) # returns the new state
```

For REPLs launched with `:REPLStart`, enable capture from Lua instead:

```lua
require("replconnect").setup({
  repl = { capture_plots = true, plot_limit = 50 },
  plots = { renderer = "auto", auto_open = true },
})
```

`repl.capture_plots` (default false) and `repl.plot_limit` (default 50) are forwarded
to Julia at launch. The top-level `plots` table controls editor presentation,
not capture. These launch settings do not configure externally started REPLs
attached with `:REPLAttach`.

When capture is requested, `:REPLStart` waits for the service to advertise
`plots` before completing attachment. A startup file can publish an ordinary
inspection server before the launcher hook enables capture; the launcher
refreshes initialization instead of caching that early capability snapshot.
If capture never becomes available, attachment reports a readiness error
rather than silently attaching without plots. Check Julia startup errors and
`REPLConnect.capturing_plots()` in that case.

For external REPL startup loading, use
`Base.invokelatest(() -> (mod.start(); mod.capture_plots!(true)))` in the
`atreplinit` example in [quickstart.md](quickstart.md). `:REPLStart`
respects a service already started by your startup file.

Capture can be switched at the Julia prompt at any time, including while
Neovim is attached:

- `REPLConnect.capture_plots!(true)` starts capturing; an attached editor
  creates its plot pane and shows new plots.
- `REPLConnect.capture_plots!(false)` stops capturing: plots go to the normal
  display stack again (an external viewer or window), the editor removes its
  pane, and the temporary history is deleted. Save copies (`s`) first.
- `REPLConnect.capture_plots!(true; limit = 20)` while capturing changes the
  retention, pruning the oldest files but keeping the rest.
- `REPLConnect.capturing_plots()` reports the current state.

`start()` never changes these settings. Re-enabling starts a new, empty
history. The former `start(; plots, plot_limit, history)` keywords still work
but warn; use the setters instead.

Attach as usual with `:REPLAttach`, then `:REPLPlots` toggles the pane.
Manual and automatic opening place the pane by the same `layout` trees as the
variables pane (see "Pane layouts" in [quickstart.md](quickstart.md)). By
default it sits beside the editor above a full-width horizontal terminal, above
the terminal within its column for a vertical terminal split, and in a
right-hand column without a visible Neovim REPL terminal. When the variables
pane is also open, the two share that space unless the layout string marks
them as alternatives (`vars \ plots`).
The service captures PNG (preferred) or SVG from `showable`/`show`, on both
explicit `display(p)` and implicit REPL result display. A semicolon-suppressed
assignment does not capture a plot. No workspace scanning, plotting-library
imports, or live plot objects are involved. Plain text and unsupported displays
continue through Julia's normal display stack. Rendering failures are logged to
`<socket-dir>/<pid>.log` and fall through rather than breaking the prompt.

## R (arf)

Install the [`unigd`](https://cran.r-project.org/package=unigd) package, then
use `repl = { capture_plots = true }` with `:REPLStart`, or in R:

```r
replinspect::start()
replinspect::capture_plots(TRUE, limit = 50)
```

This makes `unigd` the default graphics device. After each top-level input
that changed the device, its current page is saved as a PNG and published.
So several plots drawn by one input yield one record (the last page), and
adding to a plot (`lines()`) publishes a new record. A device opened before
capture (`pdf()`, an existing window) is not captured. `capture_plots(FALSE)`
restores the previous `device` option and deletes the history. Without
`unigd`, `capture_plots()` fails with an error and no `plots` capability is
advertised. SVG is not produced for R.

## History and actions

Plots made **before attaching** are available. The service keeps the newest
50 files by default, deleting older files. Closing the pane does not stop
capture or unsubscribe; detaching unsubscribes and clears editor state without
stopping Julia. Reattaching recovers the bounded history. Stopping/restarting
the server removes its files; history does not survive shutdown.

| Key | Action |
| --- | --- |
| `q` | hide pane |
| `Ctrl-n` / `Ctrl-p` | next / previous (pauses following) |
| `r` | refresh/reconcile retained history |
| `f` | follow latest again |
| `o` | explicitly open current file using `vim.ui.open` |
| `s` | save a permanent copy; prompts for a destination |

The pane follows new plots by default. A file can expire while browsing;
press `r` when the pane says so. Saving copies the original bytes and keeps the
original format/extension. Choose a destination **outside** the temporary plot
directory. Existing destinations are not overwritten. Saved copies survive
server shutdown; merely copying the temporary path does not preserve a plot.

## Optional renderer setup

```lua
require("replconnect").setup({
  plots = {
    renderer = "auto", -- "snacks", "image.nvim", "external", or custom adapter
    auto_open = false, -- true opens on new plots without moving editor focus
    keymaps = { close = "q", next = "<C-n>", previous = "<C-p>", refresh = "r",
                follow = "f", external = "o", save = "s" },
  },
})
```

`auto` tries Snacks first (including its terminal-support check), then
image.nvim. Install/configure one of these plugins yourself:

- [Snacks](https://github.com/folke/snacks.nvim): enable `image = { enabled = true }`
  in Snacks setup. Its image placement handles fitting and terminal graphics.
  Use `:checkhealth snacks` to diagnose terminal/conversion requirements.
- [image.nvim](https://github.com/3rd/image.nvim): configure its backend and
  processor in `require("image").setup(...)`. Follow its terminal and tmux
  setup documentation.

SVG conversion depends on the image plugin and installed conversion tools.
REPLConnect keeps the original SVG rather than relabelling it PNG. An unavailable
renderer leaves a useful text pane with external-open/save actions. **It never
silently launches a desktop viewer on every plot.** No terminal graphics
protocol is implemented by REPLConnect. Kitty, WezTerm, Ghostty and tmux support
is delegated to the renderer; non-graphics terminals can use `o`.

When no renderer is available, the pane shows `No image renderer: <reason>`
so that a silent fallback is not mistaken for a missing plot.

### Over SSH

When Neovim and Julia both run on the remote machine, the plot files are
already on Neovim's filesystem; only the terminal graphics must cross SSH.
Snacks handles this: when `SSH_CONNECTION` is set it streams image bytes
through the terminal instead of sending a local path. It still has to
recognise your *local* terminal, which can fail over SSH (or inside a remote
tmux). Check `:checkhealth snacks` on the remote, then either:

- export the matching override on the remote, e.g. `export SNACKS_KITTY=1`
  (or `SNACKS_GHOSTTY=1`, `SNACKS_WEZTERM=1`) in its shell profile, or
- set `image = { force = true }` in Snacks setup.

For tmux on the remote, enable `set -g allow-passthrough on`. SVG plots need
ImageMagick installed on the remote for conversion; PNG does not. `o` opens
the file with the remote's opener, so save (`s`) and copy it instead.

If the pane shows the plot's path but no image, Snacks is probably sending
the local path instead of streaming the image. Snacks only streams when
`SSH_CONNECTION` is set in Neovim's environment, which a tmux pane created
before attaching over SSH lacks. Either export `SNACKS_SSH=1` on the remote
(always stream; slightly slower locally) or switch within a session:

```lua
vim.keymap.set("n", "<leader>pr", function()
  require("replconnect").toggle_plots_remote() -- or (true) / (false)
end, { desc = "Toggle remote plot images" })
```

`:REPLPlotsRemote [on|off]` does the same. Switching also resends the
current plot, which helps after reattaching tmux from another machine. This
uses Snacks internals and may need updating with future Snacks releases.

To apply this automatically, set `plots.remote`:

```lua
plots = { remote = "auto" } -- default
```

- `"auto"` (default): when a Snacks renderer is first created, stream images
  only if snacks.nvim is already loaded **and** Neovim runs over SSH
  (`SSH_CONNECTION`, `SSH_CLIENT` or `SSH_TTY`). Otherwise nothing changes.
- `true`: always stream (like `SNACKS_SSH=1`). `false`: always send file paths
  (like `SNACKS_SSH=0`, overriding Snacks' own SSH detection).

It applies once per session, so a later `:REPLPlotsRemote` toggle is kept.
It only affects the Snacks renderer.

A custom adapter is a table of closures:

```lua
plots = { renderer = {
  render = function(record, context) -- context = {buf = ..., win = ...}
    -- render record.path, respecting record.mime; do not evaluate record content
  end,
  clear = function() -- remove all previously displayed images
  end,
} }
```

Core clears before selection changes, redraws, hide and detach. Resize events
request redraw; fitting/conversion remain the adapter's responsibility. Renderer
errors do not prevent external opening. Record ids are scoped to the current
attachment, not global.

## Plotting backends and display ownership

Any value with image MIME `show` methods can work; Plots.jl and Makie are **not**
core dependencies. For a static Makie route, try:

```julia
using CairoMakie
CairoMakie.activate!(; type = "png")
Makie.inline!(true)
f = Figure()
ax = Axis(f[1, 1])
lines!(ax, 1:5, (1:5).^2)
display(f)
f # also check implicit result display
```

If CairoMakie opens the macOS default image viewer, first check
`REPLConnect.capturing_plots()` in that REPL: it must return `true`.
Restart Neovim and launch a fresh `:REPLStart` after changing launcher code.
Makie normally detects the PNG-capable display automatically; if inline output
has explicitly been disabled, use `Makie.inline!(true)` to restore inline
routing. You can inspect `Base.Multimedia.displays` to check display ownership.
The editor's external fallback never opens an application unless you request it
with `o`.

For Plots.jl, try `using Plots; p = plot(1:5); display(p)` and then `p` at the
prompt. Package/backend versions may install their own displays or require
inline/static-output settings. **These recipes still require manual smoke
validation with your backend.** GLMakie/native windows are not silently
intercepted or overridden.

At startup, capture is installed once at the first evaluation after Julia's
REPLDisplay exists. If enabled at an existing prompt it installs immediately.
A display deliberately pushed later by a user/package keeps priority; capture
does not keep moving itself to the top. If a later backend consumes a plot,
configure that backend's inline/static routing, or explicitly target capture for
troubleshooting: `display(REPLConnect.PLOT_DISPLAY, p)`.

Capture renders synchronously at **display time**, so image encoding may be
expensive. The ordinary evaluation hook only performs a constant-time install
guard, independent of the dirty counter. Notifications are queued asynchronously
and bounded; stalled editors are disconnected rather than blocking rendering.
All files must be on the editor's **shared local filesystem** (for SSH, run
Neovim on the same host as Julia). Interactive HTML, HTTP servers, remote file
transfer and backend re-rendering are out of scope.

## Validation

Automated Julia tests use synthetic image values (no plotting dependency), a
real BasicREPL backend for late-defined MIME methods and explicit/implicit
results, and real sockets with multiple subscribers. Tests cover retention,
private/atomic publication, cleanup, MIME fallback, failure fallthrough,
later display owners, subscription ordering, legacy clients, queue overflow and
protocol fixtures. Synthetic warm startup/guard/display timing is reported by a
test item; it does not measure a real plotting backend's encoding cost.

Headless Lua suites: `tests/socket.lua` and `tests/plots.lua`; run with
`nvim --headless -u NONE -l tests/<file>.lua`. They use a local NDJSON server and
fake renderer, so they need no graphics terminal.

Remaining manual checklist (do not treat headless tests as graphics validation):

- Neovim terminal and external REPL, including late attach and REPL restart.
- Snacks/image.nvim in a graphics terminal, then tmux and an external fallback
  in a non-graphics terminal; resize, hide/reopen and confirm images clear.
- Plots.jl and CairoMakie: explicit/implicit display, including the evaluation
  that loads the package, inline routing and several plots in one evaluation.
- Long computation, failed rendering, selected-file pruning, follow/browse.
- Save a copy, stop the service, confirm the copy still opens.
- Measure disabled/enabled startup, no-plot evaluations and real backend display
  latency with no editor, attached editor and a stalled editor. Synthetic tests
  cannot substitute for these terminal/backend measurements.

The producer contract for future language services is in [protocol.md](protocol.md).
