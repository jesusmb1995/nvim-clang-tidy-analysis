# clang_tidy_analysis (Neovim)

Lua plugin to parse `clang_tidy.log` and show warnings in the quickfix window.

## Install

Copy this folder to your Neovim runtime path, e.g.:

```bash
cp -r clang_tidy_analysis "$HOME/Code/clang_tidy_analysis"
```

Then in `init.lua` (or `init.vim`):

```lua
vim.opt.rtp:prepend(vim.fn.expand('$HOME/Code/clang_tidy_analysis'))
```

Or use a plugin manager and point it at `$HOME/Code/clang_tidy_analysis`.

## Commands

- **`:ClangTidyShowLog [path]`**  
  Parse a clang-tidy log (default: `clang_tidy.log` in the current directory) and show all warnings in the quickfix window.

- **`:ClangTidyDiff <old_log> <new_log> [out_path]`**  
  Show only warnings that appear in `<new_log>` but not in `<old_log>`.  
  Writes the differential to `clang_tidy.diff.log` (or `out_path` if given) and opens the same list in quickfix.

## Example

```vim
:ClangTidyShowLog
:ClangTidyShowLog /path/to/clang_tidy.log
:ClangTidyDiff /path/to/old.log /path/to/new.log
:ClangTidyDiff old.log new.log /path/to/clang_tidy.diff.log
```
