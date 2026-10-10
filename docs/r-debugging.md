# R/arf: proving the build, transport and busy status

## Reproduce without manually timing commands

From the repository root, with testthat installed:

```sh
just r_tests
just arf_probe
```

The first command installs the package and runs its tests. The second launches
an isolated real arf terminal with a generated R profile (not the user's
`~/.Rprofile`), and uses the plugin's socket client directly. It:

1. Verifies arf's PID, protocol language and native build marker.
2. Asserts `busy = false` at its idle prompt.
3. Sends a command that prints a start marker, runs `Sys.sleep(3)`, and prints
   an end marker. It matches actual standalone output, not echoed input.
4. Asserts `busy = true` between those markers.
5. Asserts `busy = false` after returning to the prompt.

No variables pane, focus events, user polling settings or `nc` are involved.
The test closes the temporary console and removes its private directory.

## What previously went wrong

`src/Makevars` built `libreplinspect.a` only when the archive did not exist.
It had no dependencies on Rust source files. Subsequent `R CMD INSTALL`
commands could print `make: Nothing to be done for 'all'` and install the old
native library despite changed Rust sources. R wrappers could be newer than
that library. Passing tests that did not exercise the changed native behavior
were not evidence of a fresh build.

The archive now has a phony prerequisite so every install asks Cargo to check
its dependencies. Cargo remains incremental. A make dry-run regression test
creates both outputs first and verifies Cargo is still invoked on reinstall.

## Assumptions and evidence

| Assumption | Evidence or remaining limitation |
| --- | --- |
| The changed native library was rebuilt and loaded. | The make regression test verifies rebuilding is requested. `rs_diagnostics()` identifies the diagnostic native build; the R and arf tests require its startup log marker. A running R process must still be restarted after installation. |
| The logger works. | Startup logging is unconditional. The R test checks the file and explicitly writes another log line. Previously logs were created only on errors/state transitions, so a missing log did **not** prove the callback had failed. |
| The socket path and attached session are correct. | The arf test obtains the PID from its terminal job, connects to that PID's socket, and checks the handshake PID/language. For an existing session, compare the diagnostic PID with Neovim's attached client. |
| Requests and replies cross a real socket. | A small Rust client validates reply IDs, JSON framing and result shape, with explicit read/write timeouts. Unlike the earlier `nc` command, it keeps the connection open until a response arrives and reports errors. |
| R runs our input handler during `Sys.sleep`. | The R integration test launches the external client while R sleeps and verifies the actual wake counter increases; it does not simulate the event loop. |
| The environment heuristic detects that sleep as evaluation. | The same test verifies `last_evaluating` becomes true, not just that a ping timed out. The arf integration test checks false -> true -> false around a real evaluation. |
| A non-responsive R thread reports busy. | The Rust core test with no draining event loop verifies the 100 ms ping timeout path. Responsiveness and evaluation state are separate checks. |
| `R_GetCurrentEnv()` is a universal busy detector. | **Not established.** It returns the closest closure call environment, or the global environment if none exists. A top-level `browser()`, a primitive or evaluation using the global environment can evade this heuristic. Do not use false as a universal mutation-safety guarantee. |
| `sys.calls()` evaluated from Rust sees the original stack. | **Not established; removed.** extendr's evaluation uses `R_tryEval`, which introduces an `R_ToplevelExec` boundary. The previous claim that global-environment-relative call counting explained everything was unsupported. The current check reads the C API before invoking any R dispatch code. |
| The pane displays the returned state. | Lua pane tests cover `status.busy` and retries. The isolated arf test deliberately bypasses the pane. Actual pane refresh still depends on enter/focus triggers or configured polling; a responding busy session is labelled `evaluating`, not a popup warning. |
| A half-close caused the user's `nc` result. | Not established for that invocation. There was a separate reader-EOF reply-dropping bug, now covered by a Rust regression test. Use the independent client below instead of relying on platform-specific `nc` flags. |

R context implementation reference:
[R source: src/main/context.c](https://github.com/wch/r-source/blob/trunk/src/main/context.c)
(`R_GetCurrentEnv`, `R_tryEval`, `R_ToplevelExec`).

## Inspect an existing session

Install, then **restart arf**; restarting only the inspection server does not
reload an already-loaded native library. In arf:

```r
find.package("replinspect")
getLoadedDLLs()[["replinspect"]][["path"]]
replinspect:::rs_diagnostics()
```

The diagnostics include `native_build = "r-eventloop-probe-v1"`, the process
PID, the actual socket/log paths, the number of input-handler calls, and the
last sampled evaluation state. They report existing state: calling the
diagnostic function itself does not reclassify R as evaluating.

In another shell, use that socket path:

```sh
just r_status /tmp/replconnect-501/PID.sock 40
```

This prints 40 status samples, half a second apart. Run `Sys.sleep(5)` in arf
while sampling. Expected busy values are false, then true during the sleep,
then false again. Errors are explicit, not an empty result.

In Neovim, confirm the same PID:

```vim
:lua print(vim.inspect(require("replconnect").client("r").info))
```

`version = 0` is expected until the task callback/change tracking in Phase
18.7 is implemented. It is not evidence that status or logging has failed.
