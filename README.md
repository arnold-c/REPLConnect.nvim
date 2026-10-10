# REPLConnect

Inspect a plain Julia REPL from Neovim: a variables pane, a grid viewer for tables and arrays, runtime completion, and an opt-in static plot viewer.
Setup is in [docs/quickstart.md](docs/quickstart.md); plot capture, renderers and saving are in [docs/plots.md](docs/plots.md).

## Requirements

- Neovim 0.10 or later (window moves need it).
- A language plugin for each REPL you want to inspect (see below).
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) (pickers, plot rendering, remote plot streaming) and [image.nvim](https://github.com/3rd/image.nvim) (plot rendering).

## Installation

The core supports no language by itself: the language plugins below are optional extensions, not defaults, and none is installed with the core.
Install one for each REPL you use.
Each is an independent plugin with its own spec and options:

```lua
-- lazy.nvim
return {
  { "arnold-c/REPLConnect.nvim", opts = { --[[ core options below ]] } },
  {
    "arnold-c/REPLConnect.jl",
    dependencies = { "arnold-c/REPLConnect.nvim" },
    main = "replconnect.julia",
    opts = { command = { "julia", "--project=." }, capture_plots = true },
  },
  {
    "arnold-c/REPLConnect.R",
    dependencies = { "arnold-c/REPLConnect.nvim" },
    main = "replconnect.r",
    opts = { command = { "arf" } },
  },
}
```

A language plugin's `opts` take the same fields as the core's `repl` table (`command`, `split`, `size`, `enter`, `capture_plots`, `plot_limit`) and apply to that language only.
Language plugins register themselves when loaded, so `opts` are optional.
Precedence: language default command < core `repl` < language plugin `opts` < core `repl.<language>`.

## Language plugins (optional extensions)

`REPLConnect.nvim` ships with no languages.
Add only the ones you need:

| Language | Repository | Module |
| --- | --- | --- |
| Julia | [arnold-c/REPLConnect.jl](https://github.com/arnold-c/REPLConnect.jl) | `replconnect.julia` |
| R | [arnold-c/REPLConnect.R](https://github.com/arnold-c/REPLConnect.R) | `replconnect.r` |

`:REPLStart` only offers languages whose plugin is installed.

## Commands

| Command | Effect |
| --- | --- |
| `:REPLStart [vertical\|horizontal] [language] [switches]` | Start a REPL in a terminal split and attach |
| `:REPLAttach [pid]` | Attach to a REPL you started yourself (picker when several) |
| `:REPLDetach [language]` | Detach; the REPL keeps running |
| `:REPLStop[!] [pid\|language]` | Pick a REPL and stop its server (`!` also closes a Neovim terminal REPL) |
| `:REPLVariables [language]` | Toggle the variables pane |
| `:REPLVariableViewer [name[.field]]` | Open a table or array in a grid (`v` in the variables pane) |
| `:REPLPlots [language]` | Toggle static plot history |
| `:REPLPlotsRemote [on\|off]` | Toggle streaming plot images to a remote terminal (Snacks) |
| `:REPLLayout[!]` | Capture current pane sizes as a layout string |

Press `g?` in the variables pane for its keys.
See [docs/quickstart.md](docs/quickstart.md) for details.

## Configuration

All options, with their defaults (copy what you want to change):

```lua
require("replconnect").setup({
  exclude = {},              -- names to hide, or fun(var): boolean
  completion = true,         -- runtime completion LSP in buffers of attached REPLs' languages
  poll_interval_ms = 0,      -- refresh the visible variables pane; 0 = off
  update_while_busy = false, -- fetch changes while the REPL evaluates
  repl = {                   -- :REPLStart; these apply to every language
    split = "vertical",      -- or "horizontal"
    size = nil,              -- terminal width (vertical) / height (horizontal)
    enter = true,            -- start in terminal mode
    capture_plots = false,
    plot_limit = 50,
    -- Per-language settings belong to each language plugin (below);
    -- `julia = { ... }` etc. here still work as overrides.
  },
  layout = {
    -- One layout string per way the REPL is shown; see "Pane layouts" below.
    horizontal = [[ (editor | vars | plots | view) / repl ]],
    vertical = [[ editor | (vars / plots / view / repl) ]],
    external = [[ editor | (vars / plots / view) @ 60 ]],
  },
  plots = {
    renderer = "auto",       -- "snacks" | "image.nvim" | "external" | custom table
    remote = "auto",         -- stream images via Snacks: "auto" (over SSH, if snacks is loaded) | true | false
    auto_open = false,
    keymaps = { close = "q", next = "<C-n>", previous = "<C-p>", refresh = "r",
      follow = "f", external = "o", save = "s" },
  },
  viewer = {
    keymaps = {
      close = "q", refresh = "r", next_page = "]p", previous_page = "[p",
      scroll_right = "<Tab>", scroll_left = "<S-Tab>",
      next_slice = { "<C-n>", "]s" }, previous_slice = { "<C-p>", "[s" },
      select_slice = "<LeftMouse>",
    },
  },
})
```

### Pane layouts

Configure layouts directly in `opts.layout` (or the options passed to `require("replconnect").setup`) as strings that resemble the arrangement on screen.
Use Lua's `[[ ... ]]` strings so backslashes do not need escaping.

| Notation | Meaning |
| --- | --- |
| `a \| b` | Side by side: a on the left, b on the right |
| `a / b` | Stacked: a above b |
| `a \ b` | Exclusive alternatives sharing one location in **this layout** |
| `( ... )` | Group panes into a region |
| `region @ 35%` | Size that region to 35% of the **region that contains it**, along its parent's split |
| `region @ 60` | Size in character cells, not pixels; `@ 1` means one cell |

Pane names are `editor`, `repl`, `vars`, `plots`, and `view`.
`editor` represents your other Neovim windows and must appear exactly once.
Hidden panes are removed and single-child regions collapse.
Layouts do not open all listed panes automatically: use `:REPLVariables`, `:REPLPlots`, and `:REPLVariableViewer name` (or `v` in the variables pane).

The selected layout is:
- `horizontal` / `vertical`: the split used by `:REPLStart`, from its argument or `repl.split`; a terminal started manually is classified once.
- `external`: no REPL terminal is visible in the current tab.

#### Horizontal REPL: two columns with independent heights

Copy this into your setup options (the layouts go under `layout`, not `repl`):

```lua
repl = {
  split = "horizontal",
  command = { "julia", "--project=." },
  capture_plots = true,
},
layout = {
  horizontal = [[
    (editor @ 60% / repl) | (((plots \ view) @ 30%) / vars) @ 35%
  ]],
  vertical = [[
    repl @ 30% | editor | ((plots \ view) / vars) @ 25%
  ]],
  external = [[
    editor | ((plots \ view) @ 30% / vars) @ 40%
  ]],
},
```

The horizontal layout, with vars and either plots or view open:

```text
+--------------------------+--------------+
|                          | plots OR view| 30% height
| editor                   +--------------+
|                          |              |
|               60% height | vars         |
+--------------------------+              |
| repl                     |              |
|                          |              |
+--------------------------+--------------+
       65% width              35% width
```

There are **three independent size annotations**:
- `editor @ 60%` is a child of `/`, so it takes 60% of the **height** of the left column.
  The REPL receives the remaining height in that column.
- `(plots \ view) @ 30%` sizes the **shared region**, not just one alternative, to 30% of the **height** of the right column.
  Vars receives the remaining height.
- The final `@ 35%` applies to the entire right column, a child of `|`, so it takes 35% of the **width** of the whole layout.
  The left column gets the remainder.

Both columns here span the full screen height, so those percentages happen to be of the screen too.
Each percentage is always of the **region it sits in** (the whole screen only for the outermost one); see below.
Height percentages exclude the command line.
Status lines, separators and Neovim's minimum window sizes can constrain the result.
Sizes are applied when a layout is arranged, not continuously enforced while you resize windows.

#### How sizes share the space

Regions side by side (`|`) share their parent's **width**; stacked regions (`/`) share its **height**.
A region's share is its own percentage, or, if it has none, an equal part of what its sized neighbours leave:

- **Unsized regions divide the remainder equally.**
  In `editor | vars | plots @ 40%`, plots gets 40% and the editor and vars get 30% each.
  A single unsized region simply takes the whole remainder.
- **Percentages in a nested region are shares of that region, not of the screen.**
  In `editor | (vars @ 20% | plots) @ 50%`, the right region is 50% of the width; vars takes 20% of that region (10% of the screen) and plots the other 80%.
  The percentages of the panes in one group should therefore total 100%, or leave one unsized.
- **Alternatives (`\`) occupy one region** and are not added up; size the whole group, as in `(plots \ view) @ 30%`.
- **Without any percentages in a group**, panes keep the size they already had where possible, then use `repl.size`, a 60-cell side-pane width, or Neovim's split defaults.

When you call `setup()`, each layout is checked and **a warning names the mode and the regions** if its percentages cannot share the space as written:

| Case | Example | Warning |
| --- | --- | --- |
| Sizes exceed the space | `repl @ 30% \| editor @ 80% \| vars @ 25%` | total 135%, more than the 100% available |
| Every region sized, but short of the space | `repl @ 30% \| editor @ 50%` | leaving 20% unfilled |
| Sizes fill the space, but a region is unsized | `repl @ 30% \| editor @ 70% \| vars` | leaving no room for the 1 unsized region |

Every group is checked against its own region, however deeply it is nested.
`editor | (vars @ 30% | plots @ 30%) @ 50%` warns that the two panes total 60% of their region and leave 40% unfilled, whatever size the region itself has.
A layout that warns is still used: Neovim squeezes or stretches the panes it sizes last.
To fix one, lower a size, or leave one region unsized so it takes whatever is left.
Cell sizes (`@ 60`) depend on the screen, so the percentages of a group that contains one are not added up, though groups nested inside it are still checked.
Layout functions are checked the first time they return each distinct string.

#### Capturing sizes after resizing by hand

Arrange and resize the panes with the mouse or `<C-w>` commands, then run:

| Command | Effect |
| --- | --- |
| `:REPLLayout` | Show the current mode's layout with the sizes on screen, and copy it |
| `:REPLLayout!` | The same, and use it for the rest of this Neovim session |

The line is copied to the `"` and `+` registers, ready to paste into `layout = { ... }` in your config:

```lua
horizontal = [[ (editor / repl @ 22%) | ((plots \ view) @ 41% / vars) @ 33% ]],
```

Your config file is never edited, so paste the line in to keep it.
How the capture is built:

- **The structure comes from your layout** for the current mode: pane order, grouping and `\` alternatives are kept, and only sizes change.
  It is printed on one line with only the parentheses it needs.
- **Sizes are percentages of the region that contains them**, as in the rules above.
  The exception is a region your loaded config sizes in cells (`@ 60`): it is captured in cells.
- **One region in each group is left unsized** to take the remainder: the one containing `editor`, otherwise the last open one.
  Rounding therefore never makes the result over- or under-fill its space.
  Sizing that region is what made the others what they are, so nothing is lost.
- **An alternatives group is sized as a whole**, measured from whichever of its panes is showing.
- **Panes that are not open cannot be measured** and keep the size in your config; the message lists them.
  Open every pane first to capture them all.
- **A function layout** is captured as the string it returned this time.

Percentages are rounded to whole numbers, so re-applying a capture can land a cell or two away from what you resized.

#### Vertical REPL: terminal, editor, shared inspection column

From the same configuration:

```lua
vertical = [[
  repl @ 30% | editor | ((plots \ view) / vars) @ 25%
]],
```

```text
+-------------+--------------------+------------+
|             |                    | plots OR   |
| repl        | editor             | view       |
|             |                    +------------+
|             |                    | vars       |
|             |                    |            |
+-------------+--------------------+------------+
   30% width       remainder          25% width
```

#### External REPL: editor beside an inspection column

```lua
external = [[
  editor | ((plots \ view) @ 30% / vars) @ 40%
]],
```

```text
+------------------------+----------------+
|                        | plots OR view  | 30% height
| editor                 +----------------+
|                        | vars           |
|                        |                |
+------------------------+----------------+
       60% width              40% width
```

These layouts make plots and view exclusive **only in the modes containing `plots \ view`**.
For example, this external layout allows both at once, even if the horizontal layout still makes them exclusive:

```lua
external = [[ editor | (plots / view / vars) @ 40% ]],
```

#### Grouping, sizes, and more recipes

Precedence, from tightest to loosest, is `@`, `\`, `/`, then `|`.
Thus `editor / repl | plots / vars` means two columns, each with two stacked panes.
Parentheses make the scope explicit.
Put sizes on an exclusive **group**: `(plots \ view) @ 30%`, not `plots \ view @ 30%`.
Alternatives must be pane names, not arbitrary split subtrees; `editor` cannot be an exclusive alternative.

Copy one recipe per mode into `layout = { ... }`:

```lua
-- Full-width terminal below editor and inspection panes:
horizontal = [[ (editor | vars | (plots \ view)) / repl @ 30% ]],
-- Editor above; terminal beside vars below:
horizontal = [[ editor / (repl | vars) @ 30% ]],
-- Full-width terminal at the top:
horizontal = [[ repl @ 30% / (editor | vars | (plots \ view)) ]],
-- Editor beside a column of inspections above the terminal:
vertical = [[ editor | (vars / (plots \ view) / repl) @ 35% ]],
-- External REPL; inspections side by side along the bottom:
external = [[ editor / (vars | (plots \ view)) @ 30% ]],
```

A mode can also be a function returning a layout string.
Its `ctx.visible` lists panes to show, before exclusive alternatives are hidden:

```lua
horizontal = function(ctx)
  if #ctx.visible > 2 then
    return [[ editor / (repl | vars | (plots \ view)) @ 30% ]]
  end
  return [[ (editor | vars | (plots \ view)) / repl @ 30% ]]
end,
```

### Reusable data viewer and plot/view sharing

Press `v` on a variable in `:REPLVariables`, or run `:REPLVariableViewer name`.
Each session has one reusable viewer: selecting another variable replaces its contents and resets its page/slice instead of opening another split.
Failed requests preserve the old contents; late replies cannot overwrite a newer selection.
This is a split pane, not a separate Neovim tabpage.

With `plots \ view`, opening the viewer hides plots, and explicitly running `:REPLPlots` hides the viewer.
Closing the active pane (`q`, `:close`, or toggling plots off) restores the previous one with its contents and view position.
If there was no previous pane, the split closes normally.
Repeated switching does not create an endless cycle; detach/replacement clears the history.
Plot capture continues either way.

Even with `plots.auto_open = true`, background plots **do not evict an exclusive viewer**.
They accumulate until you switch back.
Without exclusivity, plots and view can both be visible.
Include all wanted pane names in your layout; a pane omitted from a custom layout opens to its right.

Window moves need Neovim 0.10+.
More details are in [docs/quickstart.md](docs/quickstart.md#pane-layouts).

## Performance

REPLConnect runs inside your REPL process, on the REPL's own thread.
Opt-in plot capture (`REPLConnect.capture_plots!(true)`) additionally renders supported images at display time; that encoding/file cost is separate from the ordinary inspection timings below.

- **Nothing runs during your computations.**
  Each evaluation costs about 30 µs (one atomic counter bump and a second top-level expression).
  Requests from Neovim wait until the REPL is idle, so a computation that never yields (a tight loop, BLAS, most numeric code) is not slowed at all.
- **Asking is cheap.**
  An unchanged session costs about 50 ns per check.
  After you run something, refreshing the pane takes roughly 0.2 ms for a typical workspace.
- **Opening a variable's details or a full refresh (`r`) can take longer** for very large nested structures (about 100 ms for a `Dict` of 5000 dictionaries), because sizes are measured eagerly.

> [!WARNING]
> **Do not keep the variables pane open while running performance-critical computations that yield** (code that calls `sleep`, does I/O, waits on a `Channel`, or uses `@async`).
> Those yields let the REPL answer Neovim's requests in the middle of your computation, and each answer runs on the same thread, which can cause slowdowns.
>
> By default the pane does not scan your variables while the REPL is evaluating: it shows `evaluating` and updates afterwards.
> Even so, its small status checks still run at every yield, so close the pane (or `:REPLDetach`) for timing-sensitive runs.
> `update_while_busy = true` makes this worse by also fetching variable changes during a computation.
> Leave it off unless you need live progress variables.

## Documentation

- [Quickstart](docs/quickstart.md): setup, commands, pane states
- [Configuration](docs/configuration.md) and [environment](docs/environment.md)
- [Plots](docs/plots.md) and [viewer](docs/viewer.md)
- [Protocol](docs/protocol.md), [R debugging](docs/r-debugging.md), [attribution](docs/attribution.md)

## Development

Run the test suite with `tests/run.sh`.

## License

[Elastic License 2.0](LICENSES/Elastic-2.0.txt).

---
