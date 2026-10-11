# `definition` hook for language services

This guide is for REPLConnect.jl and REPLConnect.R. It covers what a service
must implement so that `v` and `gd` work on functions in the REPLConnect.nvim
variables pane. The contract is in
[protocol.md](protocol.md#function-definitions-additive-extension), with
fixtures in `spec/fixtures/definition.json`.

## What the editor does

- `v` on a function sends `definition {path}` and shows every method in the
  viewer pane. Each method gets its signature and `file:line` as comments,
  followed by its `source`. Without `source`, it shows an excerpt of `file`
  from `line` to the first blank line.
- `gd` sends the same request and opens `file` at `line` in an editor window.
  When there are several methods, the user picks one. A method without a
  readable file but with `source` (e.g. code sent from a file to the prompt)
  is looked up in loaded buffers by the source line that names the function.
  If nothing is found that way and no location is a
  readable file (for example, everything was defined at the prompt), or the
  service lacks the capability, it warns and falls back to the language
  servers' `workspace/symbol` search.
- Both warn when a line may be out of date. If `source` is present, the
  warning appears when line `line` of `file` no longer contains its first
  line. Otherwise it appears when the file's current mtime is newer than
  `mtime`.

## Service checklist

1. Add `"definition"` to the `initialize` capabilities.
2. Handle `definition` with params `{path: [access_key, …]}`:
   - Resolve `path` with the same structural resolver as `inspect`.
   - Return invalid params (-32602) for an unknown path or a value that is
     not a function.
   - Return `{locations: [...]}`, one entry per method:
     `{signature, file?, line?, source?, mtime?}`.
3. Send `file` as an absolute path, or as a pseudo-name for prompt input
   (e.g. `REPL[3]`). Omit `file` if the location is unknown.
4. Always send `source` if the service can get it. It is both the text that
   `v` shows and the input to the staleness check.
5. Keep the request read-only and cheap: no evaluation and no package loading.
   Make sure no error escapes the handler.
6. Run the request on the REPL thread while the REPL is idle, like `inspect`.

## Julia sketch

```julia
const CODETRACKING = Base.PkgId(Base.UUID("da1fd8a2-8d9e-5ec2-8556-3022fb5608a2"), "CodeTracking")

function definition_locations(f)
    return [method_location(m) for m in methods(f)]
end

function method_location(m::Method)
    file, line = Base.updated_methodloc(m)       # Revise-corrected when Revise is loaded
    file = string(file)
    path = Base.find_source_file(file)           # resolves Base/stdlib paths; nothing if missing
    loc = Dict{String,Any}(
        "signature" => first(split(sprint(show, m), " @ ")),
        "file" => something(path, file),
        "line" => line,
    )
    src = method_source(m, path, file, line)
    src === nothing || (loc["source"] = src)
    return loc
end

function method_source(m, path, file, line)
    ct = get(Base.loaded_modules, CODETRACKING, nothing)  # present with Revise
    if ct !== nothing
        def = try Base.invokelatest(ct.definition, String, m) catch; nothing end
        def === nothing || return first(def)
    end
    startswith(file, "REPL[") && return repl_source(file)
    path === nothing && return nothing
    lines = readlines(path)
    line <= length(lines) || return nothing
    text = join(lines[line:end], "\n")
    _, stop = Meta.parse(text, 1; raise = false)  # one top-level expression
    return rstrip(text[1:prevind(text, stop)])
end

# `REPL[n]` is the n-th input of this session (same approach as CodeTracking).
# Check this against the REPL history internals of the Julia versions you support;
# the service's own input history can also be used.
function repl_source(file)
    n = parse(Int, file[6:end-1])
    hist = Base.active_repl.interface.modes[1].hist
    return try hist.history[hist.start_idx + n] catch; nothing end
end
```

Notes:

- Julia records no load time per file, so omit `mtime`. The staleness check
  works from `source`. With Revise, both `updated_methodloc` and CodeTracking
  stay current, so no warning appears.
- A generic function with many methods (e.g. `+`) returns many locations.
  Consider a cap (e.g. 200) and putting methods from `Main` first.
- Callable structs and types: `methods(T)` works on them as well, if you
  want to accept more than `Function`.

## R sketch

```r
definition_locations <- function(f, name) {
  if (!is.function(f)) stop("not a function")  # map to -32602
  signature <- paste0(name, "(", paste(names(formals(f)), collapse = ", "), ")")
  sr <- utils::getSrcref(f)
  if (is.null(sr)) {                             # no srcref: packages, keep.source = FALSE
    return(list(list(signature = signature,
                     source = paste(deparse(f), collapse = "\n"))))
  }
  srcfile <- attr(sr, "srcfile")
  file <- srcfile$filename
  if (nzchar(file) && !grepl("^(/|~)", file) && !is.null(srcfile$wd)) {
    file <- file.path(srcfile$wd, file)
  }
  loc <- list(
    signature = signature,
    line = sr[[1]],                              # first line (starts at `function`)
    source = paste(as.character(sr, useSource = TRUE), collapse = "\n")
  )
  if (nzchar(file) && file.exists(file)) {
    loc$file <- normalizePath(file)
    if (!is.null(srcfile$timestamp)) loc$mtime <- as.numeric(srcfile$timestamp)
  } else {
    loc$file <- "<console>"                      # typed at the prompt
  }
  list(loc)
}
```

Notes:

- `source()` stores the file's mtime in `srcfile$timestamp`. Console
  input gets `Sys.time()` instead, which doesn't matter because no file is
  sent for it.
- The editor's check looks for the first source line (`function(x) {`)
  inside the file's line (`f <- function(x) {`), so the assignment prefix
  is fine.
- S4 generics and R6 methods are optional. You could return one location
  per method from `methods::findMethods(name)`.

## Tests to add in the service repo

- Replay `spec/fixtures/definition.json`: an unknown path is an
  invalid-params error.
- A function defined in a temp file and loaded (`include` / `source`) returns
  an absolute `file`, the correct `line`, and `source` equal to the
  definition's text.
- A function typed at the prompt (simulate the REPL input or eval with a
  `REPL[n]` / console srcref) returns no readable `file` and does return
  `source` when available.
- Julia: a function with two methods returns two locations. A Base function
  resolves to an existing file.
- R: a function without srcref returns deparsed `source` and no `file`.
- A non-function variable gives -32602. `"definition"` appears in the
  `initialize` capabilities.

## Manual check in Neovim

1. Load a file that defines `f`, attach, open `:REPLVariables`, and put the
   cursor on `f`:
   - `v` shows the source in the viewer.
   - `gd` opens the file at `f` in the editor window.
2. Insert lines above `f` in the file and save without reloading it. `gd`
   warns that line numbers may be out of date.
3. Define `g` at the prompt:
   - `v` shows its source.
   - `gd` warns and searches the language server, then suggests `v` if it
     finds nothing.
4. Julia: on a function with several methods, `gd` offers a picker.
