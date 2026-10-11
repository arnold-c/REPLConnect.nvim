# Plan: REPLInspect — inspection, completion and plots for a plain Julia REPL

Status: **ready for review.** Decisions from discussion are recorded below;
remaining assumptions are flagged *(assumption)*.

## Goal

Provide a variables pane, a grid viewer, runtime object/column
completion and a file-based plot viewer in Neovim for a **plain Julia
REPL**, wherever that REPL runs:
a Neovim `:terminal`, a native terminal split (kitty, WezTerm, Ghostty,
iTerm2, …), tmux, or a separate window. No IJulia, no Jet, no tmux
dependency. Keep the protocol and the Neovim core language-neutral so
other REPLs (e.g. arf for R) can be added later as add-ons.

Out of scope for the plot milestone: interactive HTML plots, HTTP/TCP
listeners, backend-specific re-rendering and remote file transfer.
Browser/port support remains a future renderer extension, not a change to
the inspection transport. Sending code to the REPL (vim-slime etc.),
kernel management, R/arf (deferred) and Windows remain outside the
original inspection plan's scope.

## Decisions

| # | Topic | Decision |
| --- | --- | --- |
| 1 | Project | **Standalone project** with its own versions; no integration with or changes to jet.julia. Code ported from JetJulia is copied and then evolves independently. |
| 2 | Repo | One repo containing both the Julia package and the Neovim plugin (monorepo). **This whole workspace becomes the new project.** jet.julia code stays only as reference material while porting, and is deleted at the end (Phase 9). |
| 3 | Transport | Unix domain socket for inspection and plot notifications. Plot files use the shared local filesystem; no TCP listener in the initial implementation. |
| 4 | Loading | Development: `include` from `startup.jl`. Release: a regular precompiled package. PackageCompiler sysimage is an optional extra; `--trim` doesn't fit (see below). |
| 5 | Julia | `julia = "1.12"` minimum. |
| 6 | Platforms | Unix only. |
| 7 | Terminal | **Terminal/multiplexer independent.** Nothing may require tmux. |
| 8 | Pairing | Picker over discovered sessions. |
| 9 | Completion | In-process Neovim LSP, consumed by blink.cmp's LSP source; coexists with fatou and JETLS. |
| 10 | Sizes | Eager size for every variable, as in JetJulia; measured, lazy mode is the fallback. |
| 11 | Mutations | Keep `delete`/`clear`; refuse while the REPL is evaluating. |
| 12 | Updates | Variables remain pull-based (see "Sync triggers"); optional polling while the pane is visible, off by default. Plots use pushed metadata notifications, with a pull-based history for attach/recovery. |
| 13 | Scope | Julia, and R via arf (Phase 18). The R service is an R package with a Rust (extendr) core; JSON is encoded/decoded in Rust (`serde_json`), so no jsonlite. |
| 14 | Names | Lua module `replinspect`; commands `:InspectAttach`, `:InspectDetach`, `:InspectVars`, `:InspectView`, `:InspectPlots`. One attached session per language. Cursor offsets on the wire are UTF-8 bytes. |
| 15 | Plot ownership | Language-neutral core owns plot history presentation, pane, keymaps and renderer adapters. Language services capture displays and publish MIME-typed file records; no plotting-library knowledge in Lua core. |
| 16 | Plot rendering | Static files first: PNG preferred, SVG fallback. Optional Snacks/image.nvim adapters for an in-editor pane; explicit external opening when graphics support is unavailable. Do not implement a terminal graphics protocol ourselves. |
| 17 | Plot capture | Opt-in on the Julia side (`start(; plots = true)`); existing startup behaviour stays unchanged. Capture supported displays into a bounded file history, including before an editor attaches. Rendering cost is explicit, not part of ordinary inspection. |
| 18 | Future plots | Backend re-rendering and an interactive browser renderer are deferred extensions. A future browser listener belongs to core, not to each language service. |

### Compiled-code options

The server must run **inside the user's REPL process**, since only that
process can see `Main`. That rules some options in and some out:

| Option | Fits? | Notes |
| --- | --- | --- |
| `include` source | Dev only | No install; everything compiled on first use in each session. |
| **Precompiled package (pkgimage)** | **Yes — default** | Since Julia 1.9, package images cache native code. With stdlib-only deps, `using REPLInspect` takes milliseconds. A precompile workload (`precompile` calls running `respond` for every method on sample values) removes first-request latency for common types. Works with juliaup upgrades (recompiles automatically). |
| PackageCompiler `create_sysimage` | Optional | Bakes REPLInspect (and optionally the user's heavy packages) into a custom sysimage started with `julia -J replinspect.so`. Saves only the few ms of `using` over a pkgimage. Costs: rebuild for every Julia version, a launcher alias, and risk of version conflicts if user packages are baked in. Worth documenting for people who already use custom sysimages; not the default. |
| PackageCompiler `create_app` / `juliac --trim` | No | Produces a separate process with its own runtime, which can't read the REPL's objects. Trimming also strips the dynamic code inspection needs (`show`, `getproperty`, Tables.jl, `summarysize`). Only useful for a standalone *client*, which the Lua plugin already covers. |

Whatever the mechanism, the code paths that run for user values (`show`
of user types, Tables.jl methods) are compiled on first use, because they
depend on the user's types. Only REPLInspect's own machinery can be
precompiled.

## Requirements

1. **No measurable effect on REPL performance.**
   - No workspace inspection runs during user evaluations.
   - The per-evaluation hook remains O(1): it marks the session dirty
     (and performs a constant-time display-install guard when plots are
     enabled).
   - All inspection runs on request, on the REPL thread, while the REPL is
     idle. Opt-in plot capture necessarily renders at display time; its
     overhead is measured separately, not included in this guarantee.
2. **Read-only by default.** No `eval` method; paths are resolved
   structurally. Only `delete`/`clear` mutate, and both refuse while an
   evaluation is in progress.
3. **Stdlib-only Julia dependencies** (`Sockets`, `REPL`). Tables.jl is
   used only if already loaded.
4. **Terminal independent.** Discovery, pairing and sync must not assume
   tmux or any particular terminal.
5. **Language-neutral protocol**, documented with fixtures.

## Repository layout (target)

The workspace root is the new project. New files are added next to the
existing jet.julia files, which stay untouched as porting references
(`julia/JetJulia/`, `lua/jet/`, `tests/viewer.lua`, `tests/bootstrap.lua`)
until Phase 9 removes them. Shared root files (`README.md`,
`docs/attribution.md`, `LICENSES/`, `.gitignore`) are rewritten for the new
project in Phase 9; until then, new docs go in new files.

```
<root>/
  README.md                 rewritten in Phase 9
  LICENSES/                 kept subset (Elastic-2.0, jet.ark-MIT, IJulia-MIT as needed)
  docs/
    protocol.md             protocol v1
    attribution.md          rewritten for the ported code (Phase 9)
  spec/fixtures/*.json      protocol conformance fixtures
  julia/REPLInspect/
    Project.toml            name, uuid (new), version 0.1.0; deps REPL, Sockets; julia = "1.12"
    src/
      REPLInspect.jl        module, includes, public API (start/stop/serve)
      variables.jl          ported from JetJulia
      viewer.jl             ported from JetJulia
      protocol.jl           ported from JetJulia + new methods
      display.jl            opt-in MIME display, plot file store (Phase 10)
      columns.jl            transport-free column completion (ported)
      complete.jl           REPLCompletions + columns → protocol items
      json.jl               minimal vendored JSON
      server.jl             socket server, discovery files
      hook.jl               REPL ast transform; dirty/busy state
      precompile.jl         precompile workload
  lua/replinspect/
    init.lua                setup, commands
    config.lua
    client.lua              client interface
    socket.lua              socket connector (vim.uv pipe, NDJSON)
    discover.lua            discovery files + picker
    sync.lua                sync triggers / optional polling
    vars.lua, view.lua      pane and viewer (ported from jet.julia)
    plots.lua               language-neutral plot pane/history (Phase 10)
    renderers/              optional static-file renderer adapters (Phase 10)
    buf.lua                 small buffer/window helper (replaces jet.Buf)
    highlights.lua
    lsp.lua                 in-process completion LSP
    languages/              language registry (init.lua) and one file per language (Phase 18)
  r/replinspect/            R service for arf, Rust (extendr) transport (Phase 18)
  tests/*.lua               headless Lua tests (new files; old ones removed in Phase 9)
```

Versioning: the Julia package and the Neovim plugin share one repo version
tag. Protocol compatibility is checked at runtime by `protocol_version` in
`initialize`, so mismatched package and plugin versions fail with a clear
message.

## Protocol v1 (`docs/protocol.md`)

Framing: Unix socket, newline-delimited JSON, one JSON-RPC 2.0 message per
line, UTF-8. Requests are answered in arrival order per connection.

| Method | Params | Result | Status |
| --- | --- | --- | --- |
| `initialize` | `{protocol_version, client}` | `{protocol_version, language, language_version, pid, started_at, capabilities}` | new |
| `status` | – | `{version, busy}` | new; cheap |
| `list` | – | `{variables, length, version}` | ported |
| `changes` | `{since}` | `{version}` (no change) or `{version, assigned, removed}` or `{version, refresh: true}` | new; pull replacement for pushed `update` |
| `inspect` | `{path}` | `{children, length}` | ported |
| `viewer_page` / `table_page` | as in JetJulia | as in JetJulia | ported |
| `clipboard_format` | `{path, format}` | `{content}` | ported |
| `delete` / `clear` | as in JetJulia | as in JetJulia; error `BUSY` while evaluating | ported |
| `complete` | `{code, cursor}` | `{items: [{label, kind, detail}], start, stop}` | new |
| `plots` | – | `{plots: [record, ...]}` | Phase 10; `plots` capability |
| `plots_subscribe` | – | `{plots: [record, ...]}`; enables notifications | Phase 10; `plots` capability |
| `display` (server notification) | plot record | no reply | Phase 10; subscribed connections only |

- **Cursor units:** 0-based UTF-8 byte offsets.
- **`version`:** a counter that increments when an evaluation starts and
  when `delete`/`clear` run. (R increments after each top-level
  evaluation instead; see Phase 18, R5.)
- **Errors:** JSON-RPC standard codes, plus `BUSY` (-32001).
- **Variable schema:** keeps the Positron vocabulary (`kind`,
  `access_key`, `display_value`, …).

## Sync triggers (terminal independent)

Neovim calls `status`, and then `changes(since)` only if the version
moved, when any of these fire:

| Setup | Trigger |
| --- | --- |
| Neovim `:terminal` running the REPL | `TermLeave` / `WinLeave` from the REPL terminal buffer, and `WinEnter` on the pane. No focus events needed. |
| Native terminal splits or separate windows (kitty, WezTerm, Ghostty, iTerm2, Alacritty, foot, …) | `FocusGained`. These terminals report focus to the focused split/window by default. |
| tmux | `FocusGained`; requires `set -g focus-events on` (documented, not required by design). |
| Any | Pane open, pane `BufEnter`/`WinEnter`, `:InspectVars`, manual `r` refresh, optional `poll_interval_ms` while the pane is visible. |

Picker ordering heuristic: sessions whose pid descends from a Neovim
terminal job (`jobpid`) sort first, then sessions whose cwd matches
Neovim's cwd. This is optional and works without tmux.

## Phases and steps

Each step is one jj change (`jj new`, then `jj describe`) titled
`component: summary`, with the body stating its purpose and whether it is
structural or behavioural. Run the smallest relevant tests after each
step: `juliati julia/REPLInspect` and
`nvim --headless -u NONE -l tests/<file>.lua`. Format Julia
with `fatou format`.

### Phase 0 — Scaffold and baseline

- **0.1** Create `julia/REPLInspect` (Project.toml with a new UUID; test extras `Test`, `Tables`,
  `DataFrames`) and an empty module with the `@testitem` no-op macro.
  Make sure `juliati` finds it.
- **0.2** Port `variables.jl`, `viewer.jl`, `protocol.jl` and the
  transport-free part of `columns.jl` (`COLUMN_CONTEXT`, `lookup`,
  `column_completion`, `column_text`) with their test items. Bring the
  provenance headers in each file (ELv2 for the Positron.jl-derived parts,
  IJulia MIT where `columns.jl` still adapts IJulia code). The existing
  `LICENSES/` files already cover them.
- **0.3** *(test-only)* Benchmark test item for
  `snapshot`/`collect_variables`: 1 000 small globals, one large nested
  `Dict`, one 10⁷-element array, and a type with a slow `show`. Report
  timings; don't assert yet.

### Phase 1 — Protocol document and fixtures

- **1.1** Write `docs/protocol.md` as above.
- **1.2** Fixtures (request → expected result shape) in `spec/fixtures/`.
  A test item replays them against `respond`.

### Phase 2 — Session state and cheap change detection

- **2.1** `hook.jl`: install an ast transform on
  `Base.active_repl_backend.ast_transforms` (via `atreplinit` if the REPL
  isn't up yet) that rewrites `ex` into
  `Expr(:toplevel, :(REPLInspect.mark_dirty!()), ex)`. Idempotent;
  `uninstall()` for tests.
  - `mark_dirty!()` increments a `Threads.Atomic{Int}` and does nothing
    else.
  - Busy: `Base.active_repl_backend.in_eval`.
  - Spot-checked on 1.13.1: the rewrite returns the value of `ex`, still
    defines modules, and the mark runs even when `ex` throws;
    `REPLBackend` has `in_eval` and `ast_transforms`. *Verify on 1.12.*
- **2.2** `changes(since)`:
  - Return immediately if `since == version`.
  - Otherwise snapshot, diff and describe the changed variables.
  - Return `refresh: true` if `since` is older than the last snapshot.
- **2.3** Cheaper fingerprint: `(objectid, typeof, length)` for mutable
  values; `hash` with a size guard for small immutables. No `show` per
  global. Document which in-place mutations are missed.
- **2.4** Sizes stay eager. Check the cost with the 0.3 benchmark; add
  `size = "eager" | "lazy"` only if needed.
- **2.5** Turn the benchmark into budget assertions: `mark_dirty!` takes
  under 1 µs, and `changes` with nothing changed is O(1).

### Phase 3 — Socket server

- **3.1** `json.jl`: minimal encode/decode
  (`Dict{String,Any}`/`Vector`/`String`/`Int`/`Float64`/`Bool`/`nothing`,
  escapes, `\u` surrogate pairs). Round-trip tests over all fixtures.
- **3.2** `server.jl`:
  - *(Revised after testing on macOS: `TMPDIR` differed between the REPL
    and Neovim, so discovery failed.)* Directory `$REPLINSPECT_DIR` if
    set, else `/tmp/replinspect-$UID/` (mode 0700, owner checked), with no
    `XDG_RUNTIME_DIR`/`TMPDIR` lookup. Originally:
    `$XDG_RUNTIME_DIR/replinspect/`, falling back to
    `$TMPDIR/replinspect/` (mode 0700), and then to
    `/tmp/replinspect-$UID/` if the socket path would exceed ~104 bytes.
  - Socket `<pid>.sock` (mode 0600). Discovery file `<pid>.json`:
    `{pid, socket, cwd, project, julia_version, protocol_version,
    started_at}`.
  - `atexit` cleanup.
  - `@async` accept loop and per-connection read loop on the REPL
    thread. Every handler runs in `try`/`catch`.
  - Logs go to `<pid>.log`, never to the terminal.
  - `serve`/`stop` are idempotent.
- **3.3** `REPLInspect.start()` = `serve()` + install the hook.
  Development `startup.jl`:
  ```julia
  atreplinit() do _
      include("/path/to/repo/julia/REPLInspect/src/REPLInspect.jl")
      Main.REPLInspect.start()
  end
  ```
- **3.4** Tests: server on a temp dir driven via `connect()`. Cover:
  - `initialize`, `status`, `list`, `changes`, `inspect`,
    `viewer_page`, `complete`
  - malformed JSON and unknown methods
  - disconnect mid-request
  - `stop()` and file cleanup

### Phase 4 — Completion in Julia

- **4.1** `complete.jl`: `complete(code, cursor; mod = Main)` returns
  `(items, start, stop)`.
  - Columns first.
  - Otherwise `REPL.REPLCompletions.completions` on the whole buffer
    (1.12 parses full text; no `find_parsestart`).
  - Map completion types to LSP kinds.
- **4.2** Tests: ported completion and column tests, after-docstring
  completion, Unicode identifiers, byte-offset cursors.

### Phase 5 — Neovim: client, pane and viewer

- **5.1** `client.lua`: interface `{id, name, language, capabilities,
  request(method, params, on_result, on_error), close}`.
- **5.2** Port `vars.lua`, `view.lua`, `highlights.lua` and the
  vars/viewer config from jet.julia. They depend only on a client.
  `buf.lua` replaces `jet.core.kernel.buf`. Keep attribution headers.
- **5.3** Tests: port `tests/viewer.lua`; add `tests/vars.lua` with a fake
  client.

### Phase 6 — Neovim: socket connector, discovery and sync

- **6.1** `socket.lua`:
  - `vim.uv.new_pipe()` with line buffering.
  - Pending requests tracked by id, with a timeout (default 5 s).
  - On disconnect, fail pending requests and fire `on_close`.
  - Callbacks run via `vim.schedule`.
- **6.2** `discover.lua`: list discovery files; drop entries with a dead
  pid or a refused socket; picker shows `cwd · project · pid ·
  started_at`, ordered by the heuristic above.
- **6.3** Commands: `:InspectAttach`, `:InspectDetach`, `:InspectVars`,
  `:InspectView [path]`. One session per language.
- **6.4** `sync.lua`:
  - Implements the trigger table above.
  - Debounced (e.g. 50 ms) so a burst of events triggers one `status`
    call.
  - Busy/stale marker in the pane header.
- **6.5** REPL restart (changed `pid`/`started_at`): mark the pane
  detached and show a re-attach hint.
- **6.6** Tests: fake NDJSON server on `vim.uv`. Cover framing, ids,
  timeouts, disconnect, discovery filtering, and the sync debounce and
  version short-circuit.

### Phase 7 — Completion LSP

- **7.1** `lsp.lua`: in-process server via `vim.lsp.start{ cmd =
  function(dispatchers) … end }` for `julia` buffers while attached.
  - Triggers `.`, `[`, `"`, `:`.
  - Full text sync.
  - `positionEncoding = "utf-8"` where possible; otherwise convert.
  - `isIncomplete = true`.
  - `labelDetails.description = "runtime"`.
- **7.2** Document blink.cmp usage (its default LSP source works) and the
  coexistence with fatou/JETLS.
- **7.3** Tests with a fake client: responses and position conversion.

### Phase 8 — Release readiness

- **8.1** Precompile workload (`precompile.jl`) covering `respond` for
  every method on representative values. Measure `using REPLInspect` and
  first-request latency.
- **8.2** Install instructions: `Pkg.develop`/`add` into a shared
  environment (e.g. `@replinspect`) stacked on `LOAD_PATH` from
  `startup.jl`, so it's available in every project without adding a
  dependency.
- **8.3** Optional PackageCompiler recipe in the docs (sysimage with
  REPLInspect), with the trade-offs above.
- **8.4** README:
  - setup and `startup.jl`
  - sync triggers per terminal (tmux focus events note)
  - commands, configuration, limitations
- **8.5** Manual end-to-end checklist for each setup: Neovim
  `:terminal`, native split, tmux.
  - attach, list, update on switch, viewer, completion
  - delete while busy
  - REPL restart
  - long computation
- **8.6** Performance check: the same workload timed with no server, with
  the server running but no client, and with a client attached and the
  pane open. Expect identical evaluation times.

### Phase 9 — Remove jet.julia and finalise the project

- **9.1** Delete `julia/JetJulia/`, `lua/jet/`, `tests/viewer.lua`,
  `tests/bootstrap.lua`, and any jet-only docs (`docs/viewer.md` content
  is folded into the new README/docs).
- **9.2** Rewrite `README.md` (from 8.4) and `docs/attribution.md` for the
  ported files, pointing at their new paths and the original upstreams.
  Prune `LICENSES/` to what the remaining code needs.
- **9.3** Review `.gitignore`, `.dockerignore` and `.sbx/` for stale
  jet.julia references.
- **9.4** Run every test suite; grep for `jet`/`JetJulia`/`IJulia`
  leftovers (other than attribution notes).
- **9.5** Push to the new repository (done by you).

### Phase 10 — File-based plot viewer

Implementation is present in `display.jl`, `plots.lua` and renderer adapters,
with protocol fixtures and automated tests. See `docs/plots.md` for usage and
remaining terminal/backend smoke tests and measurements. Headless Lua tests
need execution in an environment permitting `nvim`; graphics/backend validation
is not implied by the Julia synthetic tests. The planned per-step jj revisions
could not be created because this checkout points at a missing jj repository.

Scope: static plot files from a plain Julia REPL. Core remains
language-neutral; the Julia service is the first producer. No Jupyter
kernel, HTTP server, interactive HTML or backend-specific resizing.
This phase follows the existing phases without renumbering them.

#### Architecture and contract

```text
Julia display stack (or another language's display/device hook)
  -> private, immutable PNG/SVG file + bounded plot history
  -> metadata over the existing Unix socket
  -> core plot pane/history
  -> optional Snacks/image.nvim adapter, or external file opening
```

- A plot record is `{id, mime, path}` with optional `width`, `height` and
  `title`. `id` is unique and monotonically increasing within one server
  lifetime; dimensions, when supplied, describe the rendered pixels.
  Paths are absolute and refer to files on the shared local filesystem.
  No base64 image payloads in NDJSON and no executable content in records.
- `initialize` advertises the additive `"plots"` capability. A `plots`
  request returns `{plots: [record, ...]}` in oldest-to-newest order.
  A server-to-client `display` notification carries one new plot record:
  ```json
  {"jsonrpc":"2.0","method":"display","params":{"id":7,"mime":"image/png","path":"/tmp/replinspect-501/1234-plots/7.png"}}
  ```
- Add an explicit `plots_subscribe` request to opt a connection into plot
  notifications. It returns the current history and activates subsequent
  notifications; subscription plus snapshot must not leave an event gap.
  Core installs its handler before subscribing, merges by id and ignores
  duplicates. Legacy clients do not receive unsolicited notifications.
- This is an additive protocol-v1 extension, gated by capability, not a
  reason to reject an otherwise compatible older service. Unsupported
  languages get a clear message when `:InspectPlots` is invoked.
- Julia owns file retention and cleanup; Lua owns navigation and pane
  state. Use a configurable bound, initially 50 files. Pruning oldest
  records also removes their files. Core reconciles history on pane open
  or refresh and tolerates a selected file disappearing meanwhile.
- Use a private per-server directory under the existing socket directory
  (0700 directory, 0600 files). Write to a temporary file and rename
  before publishing. Never overwrite a published image: immutable paths
  avoid renderer caching and replacement races. Clean up on `stop()`;
  do not promise persistent history after shutdown or a crash.

#### Implementation steps

- **10.1** *(structural)* Extend the socket client interface with
  `client:on(method, callback)`, returning an unsubscribe function.
  Dispatch valid id-less notifications separately from RPC responses;
  invoke handlers through `vim.schedule`. Ignore unknown methods, isolate
  handler errors and remove handlers on close. In `server.jl`, introduce
  per-connection state and one serialized outbound writer shared by
  responses and notifications, so messages cannot interleave.
  - Do not write to client sockets synchronously from a display callback.
    Use bounded outbound queues; disconnect a stalled client rather than
    allow unbounded memory use or block the REPL. Files/history are the
    recovery source, not successful notification delivery.
  - Tests: fragmented NDJSON, notifications between replies, unchanged
    request settlement/timeouts, unsubscribe, close and handler failures.
    Test a slow/disconnected subscriber and mixed reply/event framing.
- **10.2** *(behavioural)* Implement the bounded file store and the
  `plots`, `plots_subscribe` and `display` contract. Add capability only
  when capture is enabled. Create/update `docs/protocol.md` and protocol
  fixtures (the document and fixtures referenced earlier in this plan
  are not yet present in this checkout).
  - Test empty history, ordering, subscription snapshot/event ordering,
    duplicate reconciliation, retention, atomic publication and cleanup.
- **10.3** *(behavioural)* Add `display.jl` with a
  `PlotDisplay <: AbstractDisplay`, enabled by `start(; plots = true)`.
  - Implement Julia's `display`/`displayable` contract, including explicit
    MIME display. Prefer `image/png`, then `image/svg+xml`, using
    `showable`/`show`; leave text and unsupported MIME output to the
    normal display stack. Do not scan globals or evaluate expressions.
  - Verify REPL display ordering on Julia 1.12+. `atreplinit` can precede
    installation of `REPLDisplay`; use a one-time lazy installation at
    the first evaluation if required. Keep `mark_dirty!` independent of
    plotting. Avoid duplicate displays, preserve other display owners
    and remove only our display on stop. Do not repeatedly force it above
    a display deliberately installed later by the user.
  - Rendering/file failures must be logged and preserve normal display
    fallback without breaking the prompt. Verify Julia's fallback
    semantics rather than assuming every exception triggers fallback.
  - Keep rendered files/metadata only, not live plot objects. Capture
    happens when the value is displayed, not when it is merely assigned.
  - Test with synthetic image-showable values (no plotting dependency):
    PNG preference, SVG fallback, explicit MIME, non-image fallthrough,
    failed rendering, world-age behaviour, lifecycle and stack ordering.
    Verify capture before attach and more than one subscriber.
- **10.4** *(behavioural)* Add `plots.lua` using `buf.lua`, wire it into
  attachment/detachment and add `:InspectPlots` to open/toggle the pane
  for the selected attached session.
  - Subscribe on attach and merge the returned history with live records.
    Closing a pane does not stop capture. Scope callbacks to their client
    so queued events from an old attachment cannot populate a new one.
  - Follow the newest plot by default; browsing backwards pauses follow.
    Configurable auto-open must not steal focus. Clear pane state and
    subscriptions on detach/restart; show an actionable empty-state or
    missing-file message rather than a renderer error.
  - Buffer-local, configurable actions: close, next/previous, refresh,
    follow latest, open externally and save a copy. Saving must copy the
    file outside the temporary history, not just expose its path.
  - Tests with a fake client/renderer: ordering/deduplication, navigation,
    follow behaviour, late attach, pruning, detach/restart and unsupported
    capabilities. No terminal graphics needed for headless tests.
- **10.5** *(behavioural)* Add optional renderer adapters, selected through
  `plots.renderer`: auto, Snacks, image.nvim, external or a custom adapter.
  - Keep adapters behind a small render/clear lifecycle interface. Auto
    tries Snacks first, then image.nvim; an unavailable renderer leaves
    a useful pane with an explicit external-open action (`vim.ui.open`).
    Do not silently launch desktop applications for every new plot.
  - Delegate terminal capability checks, fitting and resize redraw to
    the image plugin. Scaling a saved image is not re-rendering a plot.
    SVG support/conversion depends on the adapter; preserve its original
    MIME/extension rather than declaring every file PNG.
  - Clear images on hide, selection changes and detach. Mock adapters in
    tests and manually test their lifecycle in supported terminals.
- **10.6** *(docs/validation)* Document startup opt-in, `:InspectPlots`,
  keymaps, retention, external saving and optional image-plugin setup.
  Document the producer contract for future language add-ons.
  - Plots.jl/Makie integration is smoke-tested, not a core dependency.
    Verify CairoMakie/inline display routing and document backend-specific
    opt-in where required; GLMakie/native-window behaviour is not silently
    overridden. Explicit `display(p)` and implicit REPL result display
    must both be checked, including after an evaluation that loads the
    plotting package.
  - Manual checklist: Neovim terminal and external REPL; late attach;
    supported graphics terminal, tmux and non-graphics external fallback;
    hide/reopen; several plots in one evaluation; long computation;
    rendering failure; REPL restart; saving then stopping the server.
  - Measure startup, no-plot evaluations and display latency with capture
    disabled/enabled, with no editor and with an attached/stalled editor.
    Use the existing test-watch results when available; otherwise run the
    smallest relevant Julia test items and headless Lua tests per step.

#### Deferred extensions (not required for Phase 10)

- `plot_render {id, width, height, ...}` under a separate capability for
  true backend re-rendering. Plots/Makie adapters may use Julia package
  extensions; this requires a bounded live-object store and explicit
  memory/lifecycle rules. Do not retain plot objects now just for this.
- Interactive browser renderer: optional core-owned HTTP listener on
  loopback with an ephemeral port, token/origin checks and controlled
  asset serving. Language extensions supply MIME output or an adapter;
  they do not each implement a web server. Interactive HTML/scripts and
  backend endpoints require their own security and lifecycle design.
- Remote file transfer/SSH: local file paths are not a remote protocol.
  Decide artifact fetching and forwarding explicitly before supporting
  a browser or REPL on a different machine.

### Phase 11 — Configurable pane layouts

Goal: let users decide in their Neovim config where the REPL terminal, the
variables pane and the plot pane go, Zellij-layout style, per terminal mode.

- `layout.{horizontal,vertical,external}` are trees of pane names
  (`editor`, `repl`, `vars`, `plots`) in `row`/`col` containers with
  optional `size`; or functions `ctx -> tree`. `layout.exclusive` lists
  groups of panes that replace each other. Trees replace the defaults
  whole (no index-wise merging) and are validated in `setup`.
- Mode: the split `:InspectStart` used (stored in the terminal buffer),
  else inferred once from the terminal's window; `external` when no REPL
  terminal is visible in the tab.
- Hidden panes are pruned; a container left with one child collapses into
  it and passes on its size.
- Realisation (`layout.lua`): siblings of `editor` become top-level splits,
  innermost level first so outer levels wrap inner ones; editor-free
  subtrees are built by splitting their first window. Existing windows are
  moved with `nvim_win_set_config` (Neovim 0.10+), so handles and the
  terminal job survive. Sizes: a moved window's previous size (unless it
  spanned the tab) > tree `size` > `repl.size` / 60-column side panes.
- Limitation: a container holding `editor` must hold it as a direct child
  at each level; user windows are never split apart.

Steps:

- **11.1** *(structural)* `Buf.open` takes a window opener instead of a
  placement; `Buf.placement` is removed. Panes and `repl.open_split` go
  through `layout.show`, whose defaults reproduce the old placement.
- **11.2** *(behavioural)* Layout trees, pruning, realisation and sizes.
- **11.3** *(behavioural)* `exclusive` groups.
- **11.4** Config validation, docs (`docs/quickstart.md` "Pane layouts",
  `docs/plots.md`) and `tests/layout.lua`, which compares
  `vim.fn.winlayout()` with the expected tree per scenario.

Status: implemented in one pass. jj revisions could not be created (the
checkout points at a missing jj repository), and the headless Lua tests
still need a run where `nvim` is available:
`tests/run.sh tests/layout.lua tests/repl.lua tests/plots.lua tests/vars.lua tests/plots_toggle.lua`.

### Phase 12 — Reusable layout-managed data viewer

- Add `view` to layout pane names and default trees. One buffer per attached
  client is reused when selecting another variable; pages/slices reset.
- Route both `v` and `:InspectView` through the registered layout opener.
  Closing/exclusive replacement hides the viewer; detach, disconnect and
  session replacement wipe it and invalidate pending replies.
- Generation guards prevent stale selection/page replies overwriting newer
  selections. Failed selections preserve the previous contents and mappings.
- `exclusive = { { "plots", "view" } }` shares a region. Explicit plot
  opening hides the viewer; background auto-open does not evict it.
- README/quickstart examples and `tests/view_reuse.lua` cover reuse, failures,
  races, exclusivity, auto-open and teardown. Behavioural change, with window
  opening injected into the viewer to keep layout dependencies explicit.

Implemented; headless tests still require an environment with Neovim:
`tests/run.sh tests/view.lua tests/view_reuse.lua tests/layout.lua tests/plots.lua tests/plots_toggle.lua tests/vars.lua tests/stop.lua`.
No test watcher or Neovim executable is available in this sandbox; jj still
points at a missing repository, so revisions cannot be created here.

### Phase 13 — Restore replaced exclusive panes

Behavioural: exclusive replacements retain a per-window/tab history. Closing
an active pane restores the most recent valid alternative with its buffer,
window options and view position. Replacement closes do not restore panes;
repeated switching removes cycles. Restoring plots redraws its renderer.
Session viewer teardown discards associated history before wiping buffers.
Closures in other tabs restore on entering that tab. An explicit new opening
cancels a pending restoration in that tab.

Implemented with regression coverage in `tests/view_reuse.lua` and updated
README/quickstart documentation. Tests require execution outside this sandbox
(no Neovim executable here): `tests/run.sh tests/view_reuse.lua tests/layout.lua tests/plots.lua tests/plots_toggle.lua tests/stop.lua`.

### Phase 14 — Visual layout strings and mode-local alternatives

Behavioural: accept strings directly in `opts.layout` and from layout
functions. A non-evaluating recursive-descent parser compiles | (rows), /
(columns), \\ (exclusive alternatives), @ sizes and parentheses to the
existing tree. Precedence: @ > \\ > / > |. % sizes are fractions of the
screen; bare sizes are cells, including @1. Errors identify the option and
character position. Alternative groups contain unsized pane names and cannot
include editor; annotate the parenthesized shared region.

Resolve mode-local groups before hiding panes and before plot auto-open checks.
Global table `exclusive` remains additive across modes. Tables do not expose
local groups. Buffer discovery is shared between opening and auto-open checks,
so the same terminal mode and function context select both policies.

Sizing: explicit annotations now take priority over remembered sizes, including
editor annotations; unsized siblings take the remainder rather than restoring
stale dimensions. This supersedes Phase 11\'s sizing precedence.

README makes string layouts primary, with horizontal, vertical and external
ASCII diagrams and detailed size scopes. Table fallback documents its global
exclusivity limitation. Quickstart follows the same recommendation.
`tests/layout_expr.lua` covers compilation, precedence, errors, README recipes,
real window sizes and layout-local exclusivity/restoration. Viewer reuse tests
now exercise local exclusivity and background plot protection.

Implemented; validation requires Neovim outside this sandbox:
`tests/run.sh tests/layout_expr.lua tests/layout.lua tests/view_reuse.lua tests/view.lua tests/repl.lua tests/plots.lua tests/plots_toggle.lua tests/stop.lua`.

### Phase 15 — Layout strings only

Behavioural (breaking): row/col table layouts and the global
`layout.exclusive` option are removed as config options. Layout strings are
the only input; they still compile to the internal
`{ name } / { dir, children, size }` tree used by pruning and arrangement.
Defaults are strings. Non-string layouts get a plain "expected a layout
string" error and unknown `layout.*` keys are rejected; there are no
table-specific migration messages. Layout functions must return strings.
Tests and README/quickstart/plots docs are updated accordingly.

### Phase 16 — Size checks and equal remainders

Behavioural: `layout.check_sizes` computes each region's screen share per
axis (its % or an equal part of its sized siblings' remainder) and warns at
setup, once per string, when sibling percentages exceed the parent's share,
when all siblings are sized but under-fill it, or when they fill it while
unsized siblings remain. Groups containing cell sizes, and their contents,
are not checked; alternatives are never summed. Layout functions are checked
per distinct returned string. Arrangement divides the space left by sized
regions equally among unsized regions (`share_remainder`). README documents
the rules with a warning table; tests cover messages, nesting, README recipes
and real equal division.

Correction: percentages are shares of the enclosing region (the screen only
for the outermost), not of the screen. Every group's sibling percentages are
checked against 100% regardless of nesting; `apply_sizes` computes each
region's cells from its parent's (`child_regions`), and a region sized along
its own split is sized through its children.

### Phase 17 — Capture layout sizes

Behavioural: `:InspectLayout[!]` (`layout_capture.lua`) measures the open
panes against the current mode's configured layout and prints it as a
layout string (`serialize`, minimal parentheses, round-trips through
`parse`). Sizes are percentages of the containing region, except regions
configured in cells, which stay cells. In each group one visible region is
left unsized as the remainder (editor-containing, else last visible not in
cells), so the capture never triggers size warnings. Alternatives are sized
as a group; hidden panes keep their configured sizes and are listed. The
line is copied to the " and + registers; ! applies it for the session only.
Config files are never edited. Tests: `tests/layout_capture.lua`.

### Phase 18 — R service for arf

Goal: the same panes, viewer, completion, history and plots for an R
session running in [arf](https://github.com/eitsupi/arf), through the
unchanged protocol v1. Plain `R` should work incidentally (its
`ReadConsole` also runs input handlers); radian is untested.

#### Decisions

| # | Topic | Decision |
| --- | --- | --- |
| R1 | Package | `r/replinspect/`: an R package (`replinspect`) whose transport is a Rust crate built with extendr (`rextendr::use_extendr()`). R code implements the inspection methods; Rust owns sockets, threads, framing and JSON. |
| R2 | Event loop | A listener thread accepts connections; per-connection reader/writer threads exchange messages with the R thread through channels. The R thread is woken through a self-pipe registered with `addInputHandler`. arf's `process_r_events()` runs `R_checkActivity`/`R_runHandlers` ~30×/s at the prompt, so requests are handled on R's main thread only while R is idle, just as the Julia service handles them only while the REPL is idle or yielding. |
| R3 | R safety | The worker threads never touch R objects. Every call into R from Rust is wrapped in extendr's error catching (R errors longjmp and would skip Rust destructors). Handlers return plain R lists; Rust converts them with `serde_json` on the R thread and hands strings to the writer. |
| R4 | Busy | R cannot answer while evaluating, so the Rust side answers `status` itself from atomics: `version` (bumped by the task callback) and `busy` (a request has waited > 100 ms for the R thread). Other requests wait in the queue and may time out client-side, as with Julia. |
| R5 | Version | `addTaskCallback` increments the counter **after** each top-level evaluation (R has no pre-eval hook). Documented in `docs/protocol.md`. |
| R6 | Dependencies | Imports: none beyond base/utils/grDevices. Suggests: `unigd` (plots), `tibble`, `data.table`, `testthat`. |
| R7 | Plots | Opt-in `start(plots = TRUE)` with `unigd` as the default device; the task callback compares `ugd_state()$upid` and publishes PNG records through the same file store contract as Julia. Without `unigd`, the `plots` capability is not advertised. *(assumption)* |
| R8 | Language per filetype | The Lua core keeps one session per language. A language registry maps filetypes to languages (`julia` → julia; `r`, `rmd`, `rnoweb` → r; `quarto` is left out because its chunks may be in any language). Commands without an explicit language use the current buffer's filetype; in a vars/view/plots pane or REPL terminal they use that pane's language; otherwise the only attached session, else a `vim.ui.select` prompt. Completion attaches per filetype to its own language's session, and `:InspectStart` in an R buffer launches arf. |
| R9 | arf IPC | Not used. Its silent eval needs a startup allowlist, rejects requests while the user types, uses HTTP framing with one request per connection and has no notifications. |
| R10 | Startup | `if (interactive()) replinspect::start()` in `~/.Rprofile`. `:InspectStart` points `R_PROFILE_USER` at a generated profile that sources the user's profile and then starts the service *(assumption: verify arf honours `R_PROFILE_USER`; `--vanilla` skips it)*. |

Layout additions:

```
r/replinspect/
  DESCRIPTION, NAMESPACE
  R/          start.R, hook.R, variables.R, viewer.R, complete.R,
              columns.R, history.R, plots.R, respond.R
  src/rust/   Cargo.toml, src/{lib,server,framing,discovery,convert}.rs
  tests/testthat/
lua/replinspect/languages/{init,julia,r}.lua
```

#### Steps

Lua first (structural, Julia keeps working), then the R service.

- **18.1** *(structural)* `languages/` registry: `{name, filetypes,
  prompt, repl = {command, build_cmd, bootstrap}, trigger_characters}`
  for `julia`; move the Julia launcher/bootstrap from `repl.lua` into
  its entry. Add `"language": "julia"` to Julia discovery files
  (`server.jl`). Tests: `tests/repl.lua`, `tests/picker.lua`.
- **18.2** *(behavioural)* Language resolution (R8): replace the
  `"julia"` defaults in `init.lua` (`client`, `detach`,
  `require_client`, `capture_layout`) with `languages.resolve(bufnr)`.
  Commands take an optional language argument. Picker label shows the
  language; preview prompt and highlighting come from the registry.
  Tests with fake clients for two languages.
- **18.3** *(behavioural)* Per-language completion: attach the LSP by
  the registry's filetypes, one server name per language
  (`replinspect-julia`, `replinspect-r`) resolving its own client;
  per-language trigger characters (R: `$ @ : [ " (`). Tests:
  `tests/lsp.lua`.
- **18.4** *(behavioural)* `r` registry entry: `:InspectStart` from an
  R buffer (or `:InspectStart r`) runs `arf` with the generated profile
  (R10). `repl` fields are shared by every language; `repl.julia` and
  `repl.r` override them and set `command`. Only the flat
  `repl.command` is deprecated (it means `repl.julia.command`). R API
  names: `replinspect::start()`, `shutdown()` (not `stop()`, which would
  mask `base::stop`), `capture_plots(enable, limit)`.
- **18.4b** *(behavioural)* Reconnect after an in-place restart: when a
  session hosted in a Neovim terminal disconnects but the terminal job
  is still running (arf's `:restart`/`:switch` exec in place and keep
  the pid), wait for a discovery record from that terminal with a newer
  `started_at` and attach to it.
- **18.5** *(scaffold)* `r/replinspect` with extendr, `cargo test` for
  the pure-Rust parts, testthat for R. The Rust is split into
  `replinspect-core` (pure Rust: sockets, framing, JSON, discovery,
  queues; tested with `cargo test` without R) and a thin extendr glue
  crate that needs an R installation to build. Code adapted from
  posit-dev/ark needs ark's own MIT notice in `LICENSES/` and
  `docs/attribution.md` (`jet.ark-MIT.txt` covers jet.ark only).
- **18.6** *(behavioural)* Rust server (R2–R4): socket dir and
  discovery identical to Julia (`/tmp/replinspect-<uid>`, 0700/0600,
  owner check, path-length check), discovery
  `{pid, socket, cwd, project, language: "r", r_version,
  protocol_version, started_at}`, NDJSON framing, bounded outbound
  queues (64 messages / 16 MiB), `shutdown`, log file, idempotent
  `start()`/`stop()`, cleanup via `reg.finalizer(onexit = TRUE)`.
  Stale sockets are replaced (exec restarts reuse the pid). The
  discovery `started_at` must equal `initialize`'s: clients use it to
  tell an in-place restart's new server from the stale record (18.4b). Declare
  `addInputHandler`/`removeInputHandler`/`R_InputHandlers` with
  `extern "C"` if `libR-sys` lacks them *(assumption)*. Cargo tests:
  framing, malformed JSON, unknown methods, disconnect mid-request,
  queue overflow, off-thread `status`.
- **18.6a** *(build/validation)* Reinstall must invoke Cargo even when
  the archive/shared library already exist (phony prerequisite in Makevars).
  Add a native diagnostic build marker, unconditional startup log and wake
  counter; a standalone Rust socket client; a real-R sleep integration test;
  and `just arf_probe` asserting idle -> busy during Sys.sleep -> idle in a
  fresh arf terminal. Evidence and remaining assumptions are recorded in
  `docs/r-debugging.md`. The current-environment check is a closure heuristic,
  not proof of safe mutation at every nested prompt (notably top-level
  browser()); settle that before 18.10.
- **18.7** *(behavioural)* `hook.R`: task callback that bumps the
  version through a Rust export and records the deparsed expression for
  `history`; nothing else (O(1) besides the deparse; measure it).
- **18.8** *(behavioural)* `variables.R`/`respond.R`: `initialize`
  (`language = "r"`, `language_version`), `list`, `changes`, `inspect`
  for atomic vectors, lists, environments, data frames/tibbles,
  factors, S4 slots and R6 fields, using the Positron vocabulary.
  Fingerprint: the object's memory address (`rs_address`, from the Rust
  glue; a reassigned value is a new object) with type, class, length,
  dimensions and names, plus the value itself when small. In-place
  changes to large objects that keep their size are missed (listed in
  `variables.R`). Benchmark like 0.3 and adopt lazy sizes if eager
  `object.size` is too slow *(assumption)*.
- **18.9** *(behavioural)* `viewer.R`: `viewer_page`/`table_page` for
  data frames, tibbles, data.table, matrices and arrays (slices);
  `clipboard_format`.
- **18.10** *(behavioural)* `delete`/`clear` on the global environment;
  refuse (BUSY) when called from a nested prompt (`browser()`,
  `readline()`), since R is then mid-evaluation.
- **18.11** *(behavioural)* `complete.R`: `utils:::.assignLinebuffer`,
  `.assignEnd`, `.guessTokenFromLine`, `.completeToken`,
  `.retrieveCompletions` on the line at the cursor, plus `columns.R`
  for `df$`, `df[["`, `df[, "`. Convert UTF-8 byte offsets at the
  boundary. Map completion kinds (function, variable, package,
  argument, file).
- **18.12** *(behavioural)* `history` capability from the task callback
  ring buffer (`record_history(FALSE)` turns it off).
- **18.13** *(behavioural)* Plots (R7): bounded private file store,
  `plots`/`plots_subscribe`/`display`, `capabilities` notification when
  toggled; `capture_plots(TRUE/FALSE)`.
- **18.14** *(docs/validation)* testthat replays `spec/fixtures/*.json`
  against `respond()`; README/quickstart R section; manual arf
  checklist (attach, list, update on switch, viewer, completion, busy
  status during `Sys.sleep(10)`, delete while in `browser()`,
  `:restart`, plots). `docs/protocol.md`: discovery `language`, R5,
  off-thread `status`.

### Phase 19 — Function definitions

Behavioural, additive `definition` capability (docs/protocol.md,
`spec/fixtures/definition.json`, service guide `docs/definition-hook.md`).
In the variables pane, `v` on a function shows each method's source in the
reusable viewer; `gd` opens the defining file at its line in an editor
window, picking among methods with `vim.ui.select`. Stale lines are warned
about (source's first line not on that line, else file mtime newer than
loaded). Without a readable file or the capability, `gd` warns and falls
back to other language servers' `workspace/symbol`. Editor side in
`definition.lua`; Julia/R services are implemented in their own repos.
Tests: `tests/definition.lua` (needs Neovim).

### Later

- Hover and signature help.
- Optional plot re-rendering and interactive browser renderer (above).

## Risks

- **Display ownership/order:** Julia and plotting packages may install
  competing displays. Verify lazy installation and fallthrough with the
  real REPL, not only isolated `pushdisplay` unit tests.
- **Plot capture is not free:** `show` may render slowly, allocate heavily
  or fail. It is opt-in; keep socket delivery out of that hot path and
  bound both file storage and client queues.
- **Image support is terminal-dependent:** Snacks/image.nvim do not make
  every terminal graphical. Keep an explicit external-open fallback and
  test image clearing, tmux and resize behaviour.
- **Temporary plot lifetime:** pruned files and server shutdown invalidate
  paths. Refresh/reconcile history, tolerate missing files and offer a
  save-copy action. Shared local filesystem is an explicit limitation.
- **ast transform and `in_eval` on 1.12.** Both are REPL internals;
  confirmed on 1.13.1 only. Fallback: a busy flag maintained by the
  hook.
- **Requests during yields inside user code.** A handler may read
  half-updated globals. Reads are side-effect free and mutations are
  refused while busy, so this is acceptable.
- **Eager `summarysize` on huge objects** may delay the prompt after a
  refresh. It's measured (0.3, 2.4); lazy mode is the fallback.
- **Focus reporting varies by terminal.** The fallbacks are pane
  enter/open, the `r` key and optional polling. Nothing depends on focus
  events alone.
- **Socket path length**: the default `/tmp` path is short; a long
  `REPLINSPECT_DIR` fails at start with a clear message (3.2).
- **macOS `/tmp` cleanup** may remove files not accessed for 3 days, so a
  long-lived REPL could lose its socket. Restart the server or set
  `REPLINSPECT_DIR`.
- **Stale discovery files** after crashes; clients check the pid and the
  socket.
- **Ported code drifts from JetJulia.** That's intended (decision 1);
  provenance notices must still be kept.
- **arf internals (Phase 18).** Request handling depends on arf
  running R input handlers while idle (true as of
  `arf-libr/src/sys/interrupt.rs`); `R_PROFILE_USER` support is
  unverified. arf is pre-1.0, so re-check after upgrades.
- **Rust toolchain for R installs.** Source installs need cargo;
  publish binaries (r-universe) and vendor crates if CRAN is a goal.
- **R errors crossing Rust frames.** Every R call from Rust must go
  through extendr's error catching; a missed one can leak or abort.
- **Old and new code side by side until Phase 9.** Keep the new code
  free of `jet`/`IJulia` references so the deletion is mechanical.
