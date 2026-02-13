# clang_tidy_analysis (Neovim)

Lua plugin to parse clang-tidy logs and show warnings in the quickfix window. Supports generating logs (old/new), diffing them, and optional progress reporting via [fidget.nvim](https://github.com/j-hui/fidget.nvim).

## Install

Copy this folder to your Neovim runtime path, or use a plugin manager.

**Manual:**

```bash
cp -r clang_tidy_analysis "$HOME/Code/clang_tidy_analysis"
```

Then in `init.lua` (or `init.vim`):

```lua
vim.opt.rtp:prepend(vim.fn.expand('$HOME/Code/clang_tidy_analysis'))
```

**Lazy.nvim:** add to your plugin spec (e.g. `lua/plugins/clang_tidy_analysis.lua`):

```lua
return {
  "jesusmb1995/nvim-clang-tidy-analysis",  -- or your fork
  lazy = true,
  cmd = {
    "ClangTidyShowLog",
    "ClangTidyDiff",
    "ClangTidyGenerateOld",
    "ClangTidyGenerateNew",
    "ClangTidyGenerateNewDiff",
    "ClangTidyGenerateDiff",
  },
}
```

## Intended behavior

- **Log files:** By default the plugin uses `clang_tidy.old.log`, `clang_tidy.new.log`, and `clang_tidy.diff.log` in the current working directory. You can override paths per command.
- **Diff deduplication:** When diffing, a “new” warning is hidden if it matches the old log by:
  - **Location:** same file, line, column, and message;
  - **Content:** same message plus normalized continuation lines (handles renames);
  - **Message only:** same warning message text (e.g. same diagnostic in another file).
- **Progress:** If [fidget.nvim](https://github.com/j-hui/fidget.nvim) is loaded, background generate tasks report progress from clang-tidy stdout (e.g. `[2/3] Processing file …`, `N warnings generated`).

## Commands

### View logs

- **`:ClangTidyShowLog [path]`**  
  Parse a clang-tidy log and show all warnings in the quickfix window.  
  Default path: `clang_tidy.log` in the current directory.

### Diff logs

- **`:ClangTidyDiff [old_log] [new_log] [out_path]`**  
  Show only warnings that appear in the new log but not in the old log (after deduplication).  
  Writes the result to `clang_tidy.diff.log` (or `out_path`) and opens it in the quickfix list.  
  **Defaults:** `old_log` = `clang_tidy.old.log`, `new_log` = `clang_tidy.new.log`, `out_path` = `clang_tidy.diff.log`.  
  With no arguments, uses all three defaults.

### Generate logs (background)

- **`:ClangTidyGenerateOld <folder>`**  
  Run clang-tidy on all `*.cpp` under `<folder>` (e.g. `addon`) and write output to **`clang_tidy.old.log`**.  
  Uses `-p build` and `--config-file=.clang-tidy` by default. Progress is reported via fidget if available.

- **`:ClangTidyGenerateNew <folder>`**  
  Same as above but writes to **`clang_tidy.new.log`**.

### Generate + diff (combined)

- **`:ClangTidyGenerateNewDiff <folder>`**  
  Run **ClangTidyGenerateNew** for `<folder>`, then run **ClangTidyDiff** when the job finishes.  
  Requires `clang_tidy.old.log` to already exist.

- **`:ClangTidyGenerateDiff <folder> [branch]`**  
  Full baseline vs current comparison:
  1. If **`branch`** is given: check out that branch.
  2. If **`branch`** is omitted: open a GUI (vim.ui.select) to pick a branch.
  3. On the chosen branch: run **ClangTidyGenerateOld** for `<folder>` and wait for it to finish.
  4. Check out the original branch again.
  5. Run **ClangTidyGenerateNew** for `<folder>` and wait.
  6. Run **ClangTidyDiff** and show the result in the quickfix list.  
  Output files: `clang_tidy.old.log` (from baseline branch), `clang_tidy.new.log` (current branch), `clang_tidy.diff.log` (new warnings only).

## Examples

```vim
" View a log (default: clang_tidy.log)
:ClangTidyShowLog
:ClangTidyShowLog /path/to/clang_tidy.log

" Diff with default files (clang_tidy.old.log vs clang_tidy.new.log → clang_tidy.diff.log)
:ClangTidyDiff

" Diff with explicit paths
:ClangTidyDiff /path/to/old.log /path/to/new.log
:ClangTidyDiff old.log new.log /path/to/clang_tidy.diff.log

" Generate old and new logs (e.g. for directory 'addon')
:ClangTidyGenerateOld addon
:ClangTidyGenerateNew addon

" Generate new log then diff (old log must exist)
:ClangTidyGenerateNewDiff addon

" Generate diff: pick baseline branch from GUI, then compare with current branch
:ClangTidyGenerateDiff addon

" Generate diff: use branch 'main' as baseline
:ClangTidyGenerateDiff addon main
```

## Requirements

- Neovim (tested with 0.9+).
- `clang-tidy` and a build directory with `compile_commands.json` (e.g. `-p build`).
- Optional: [fidget.nvim](https://github.com/j-hui/fidget.nvim) for progress reporting during generate tasks.
