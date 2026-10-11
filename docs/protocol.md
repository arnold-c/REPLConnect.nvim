# REPLConnect protocol v1

Transport: local Unix-domain socket, UTF-8 newline-delimited JSON. Each line is
one JSON-RPC 2.0 message. Requests have an `id`, `method` and optional `params`;
responses preserve that id and have either `result` or `error: {code, message}`.
Requests are answered in arrival order per connection. Notifications have no id.
Cursor offsets and completion ranges are zero-based UTF-8 byte offsets.

Discovery: each service writes `<dir>/<pid>.json` next to its socket, with
`pid`, `socket`, `cwd`, `project`, `language` (the same name `initialize`
returns, e.g. `"julia"`), `protocol_version` and `started_at`, plus
language-specific extras such as `julia_version`. Clients treat a missing
`language` as `"julia"` (older services).

Call `initialize` with `{protocol_version: 1, client: "client name"}`.
The result has `protocol_version`, `language`, `language_version`, `pid`,
`started_at` and a string array `capabilities`. Reject a protocol version
mismatch; ignore unfamiliar additive capabilities.

Editor ownership: a REPL launched by an editor (`:REPLStart`) gets
`REPLCONNECT_EDITOR_PID` in its environment. The editor stops such REPLs when
it exits (SIGTERM, then SIGKILL after a grace period). To cover an editor that
dies without exiting cleanly, a service should, when this variable is set and
the process is interactive, check periodically (every few seconds, off the hot
path) whether that pid is still alive and quit the REPL when it is not. The
variable is set only for the launched process: services should remove it from
their own environment at startup so child processes do not inherit it.
Services should also not start at all in non-interactive processes.

## Inspection

| Method | Params | Result |
| --- | --- | --- |
| status | — | {version, busy} |
| list | — | {variables, length, version} |
| changes | {since} | {version}, {version, assigned, removed}, or {version, refresh: true} |
| inspect | {path: [access_key, …]} | {children, length} |
| viewer_page / table_page | see source and viewer docs | paginated grid |
| clipboard_format | {path, format} | {content} |
| delete | {names: [name, …]} | mutation result |
| clear | — | mutation result |
| complete | {code, cursor} | {items: [{label, kind, detail}], start, stop} |
| definition | {path: [access_key, …]} | {locations: [location, …]} (definition capability) |
| history | — | recent input records (history capability) |
| shutdown | — | {} then the service stops serving (shutdown capability) |
| capabilities (server notification) | {capabilities: [string, …]} | sent to every connection when they change (plots, history) |

`status` must stay cheap and answer even while the REPL evaluates. The R
service answers it on a transport thread: it pings R's main thread and reports
`busy: true` if R does not respond within 100 ms or the input handler detects
that it is inside an active non-global closure. R can service input handlers
during `Sys.sleep` as well as at its prompt. This evaluation heuristic is not
a complete nested-prompt detector; see [R debugging](r-debugging.md). Other
requests wait for R's input handler.

`shutdown` stops the inspection server only, not the REPL process. The service
may close the connection right after (or before delivering) its reply, so
clients should treat the connection closing as a completed shutdown.

Inspection schema and paging are implemented in
`julia/REPLConnect/src/protocol.jl` and `viewer.jl`. Variable records use
`access_key`, `display_name`, `display_value`, `display_type`, `kind`,
`has_children` and size metadata. Paths are structural, not expressions.
There is no evaluation RPC. Mutations refuse while evaluating (BUSY, -32001).
Standard errors include parse (-32700), invalid request (-32600), method not
found (-32601), invalid params (-32602), and internal error (-32603).

## Static plots (additive extension)

Only services advertising `"plots"` support this extension. Julia enables it
with `capture_plots!(true; limit = 50)`; R with
`replinspect::capture_plots(TRUE, limit = 50)` (PNG only, via `unigd`; the
new plot is published after the input that drew it). Older services remain compatible.
All image bytes travel through the shared local filesystem, never NDJSON.

A record is `{id, mime, path}`, optionally `width`, `height`, `title`.
Ids are positive integers, unique and monotonically increasing within a server
lifetime (gaps after failed rendering are allowed). Supported static MIME types
are `image/png` and `image/svg+xml`; paths are absolute, immutable local files
with the matching extension. Optional dimensions describe rendered pixels.
Records contain no executable content. Files are private (0600) in a private
per-server directory (0700); publication follows a completed temporary write
and atomic rename. Producers keep metadata/files, not live plot objects.

| Method | Params | Result |
| --- | --- | --- |
| plots | — | {plots: [record, …]} oldest to newest |
| plots_subscribe | — | {plots: [record, …]} and enable delivery on this connection |
| display (server notification) | record | no response |

Capture can be enabled or disabled while clients are attached. The service then
sends `capabilities` with its full current list to every connection, whether
or not it subscribed. Disabling also unsubscribes connections and removes the
history; re-enabling starts a new history whose ids restart. Clients should
discard plot state when `plots` disappears and subscribe afresh when it appears.

Example:

```json
{"jsonrpc":"2.0","method":"display","params":{"id":7,"mime":"image/png","path":"/tmp/replconnect-501/1234-plots-example/7.png"}}
```

Install a notification handler **before** subscribing. Subscribe activates
delivery and snapshots history without yielding; its response and subsequent
events share one serialized writer. Thus there is no snapshot/event gap.
Merge by id, sort and ignore duplicates, including during delayed callbacks.
Connections that never subscribe receive no plot notifications. Unknown
notifications must be ignored; handler failures must not break RPC settlement.

Delivery is best-effort: display callbacks only enqueue metadata, never write
to sockets. The Julia service bounds each outbound queue to 64 messages and
16 MiB, plus at most one in-flight write, and disconnects an overflowing client.
Responses and events cannot interleave bytes. History is the recovery source,
not acknowledgement of notifications.

The producer owns retention (50 files by default), pruning oldest records and
their files, and cleanup on stop. Consumers reconcile on pane open/refresh and
handle disappearing files gracefully. Save a **copy outside the temporary
directory** before shutdown. Restart invalidates the entire old history and
all ids; consumers scope callbacks to the attached client, unsubscribe on
detach and discard old state. No persistence after a crash is promised.

## Function definitions (additive extension)

Services advertising `"definition"` answer `definition` for function
variables (`kind: "function"`). `path` is resolved structurally, like
`inspect`. The result lists one location per method (one for languages
without multiple dispatch), in the order the editor should offer them:

| Field | Required | Meaning |
| --- | --- | --- |
| signature | yes | one-line label, e.g. `f(x::Int)` or `function(x, y = 2)` |
| file | no | absolute path of the defining file; a pseudo-name such as `REPL[3]` for code typed at the prompt; absent when unknown |
| line | no | 1-based line of the definition's first line in `file` |
| source | no | the method's source text, as defined (all lines) |
| mtime | no | `file`'s modification time in seconds when it was loaded |

An unknown or non-function path is an invalid-params error (-32602); a
function without known locations returns `{locations: []}`. Send `source`
whenever it is available, including for files: the editor shows it with `v`,
and compares its first line with line `line` of `file` to warn when the file
has changed since loading. Without `source`, `mtime` serves that check, and
the editor shows an excerpt of the file. `gd` opens `file` at `line` when it is
a readable file, and otherwise falls back to the language servers'
`workspace/symbol` search. Paths require the REPL and editor to share a
filesystem. The request is read-only and may run while idle like `inspect`.
Fixtures are in `spec/fixtures/definition.json`; a guide for language
services is in [definition-hook.md](definition-hook.md).

Example:

```json
{"jsonrpc":"2.0","id":4,"method":"definition","params":{"path":["f"]}}
{"jsonrpc":"2.0","id":4,"result":{"locations":[{"signature":"f(x::Int)","file":"/home/me/project/src/f.jl","line":12,"source":"function f(x::Int)\n    x + 1\nend"},{"signature":"f()","file":"REPL[3]","line":1,"source":"f() = 0"}]}}
```

## Other language producers

Implement the same capability, snapshot/subscription and notification contract
using a language-specific display/device hook. Capture only on actual display,
not by scanning globals. Keep image rendering/file work separate from ordinary
inspection, bound storage and outbound delivery, and let unsupported displays
fall through to the language's normal output. Core owns pane navigation,
keymaps and adapters. There is no plotting-library knowledge in Lua.

Local paths require the REPL and editor to share a filesystem. Remote transfer,
HTML/JavaScript, HTTP/TCP listeners and backend re-rendering are not supported.
Fixtures for the additive extension are in `spec/fixtures/plots.json`.
