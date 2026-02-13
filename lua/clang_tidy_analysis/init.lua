--- Clang-tidy log parser and Neovim integration.
--- Parses clang_tidy.log for "path:line:col: warning:" and shows in quickfix.
--- @module clang_tidy_analysis

local M = {}

-- Pattern: path:LINE:COL: warning: message [...]
local WARNING_LINE_PATTERN = '^(.+):(%d+):(%d+): warning: (.+)$'

--- Parse a clang-tidy log file into a list of warnings and their raw blocks.
--- Each warning has: filename, lnum, col, message, key (for diff), raw_lines (full block).
--- @param log_path string path to clang_tidy.log
--- @return table[] warnings
--- @return string? err
function M.parse_log(log_path)
  local fd, err = io.open(log_path, 'r')
  if not fd then
    return {}, ('Failed to open %s: %s'):format(log_path, err or 'unknown error')
  end
  local content = fd:read('*a')
  fd:close()

  local lines = {}
  for line in (content or ''):gmatch('[^\r\n]+') do
    table.insert(lines, line)
  end

  local warnings = {}
  local i = 1
  while i <= #lines do
    local path, lnum, col, message = lines[i]:match(WARNING_LINE_PATTERN)
    if path and lnum and col and message then
      lnum = tonumber(lnum)
      col = tonumber(col)
      local key = ('%s:%s:%s:%s'):format(path, lnum, col, message)
      local raw_lines = { lines[i] }
      i = i + 1
      -- Consume continuation lines (notes, code snippets) until next warning
      while i <= #lines do
        if lines[i]:match(WARNING_LINE_PATTERN) then
          break
        end
        table.insert(raw_lines, lines[i])
        i = i + 1
      end
      table.insert(warnings, {
        filename = path,
        lnum = lnum,
        col = col,
        message = message,
        key = key,
        raw_lines = raw_lines,
      })
    else
      i = i + 1
    end
  end

  return warnings, nil
end

--- Build quickfix list from parsed warnings.
--- @param warnings table[] from parse_log
--- @return table[] qflist
local function warnings_to_qflist(warnings)
  local qf = {}
  for _, w in ipairs(warnings) do
    table.insert(qf, {
      filename = w.filename,
      lnum = w.lnum,
      col = w.col,
      text = w.message,
    })
  end
  return qf
end

--- Show warnings from a clang_tidy log file in the quickfix window.
--- @param log_path string path to log (default: clang_tidy.log in cwd)
function M.show_log(log_path)
  log_path = log_path or vim.fn.getcwd() .. '/clang_tidy.log'
  log_path = vim.fn.fnamemodify(log_path, ':p')
  local warnings, err = M.parse_log(log_path)
  if err then
    vim.notify('clang_tidy_analysis: ' .. err, vim.log.levels.ERROR)
    return
  end
  local qf = warnings_to_qflist(warnings)
  vim.fn.setqflist(qf, 'r')
  vim.cmd('copen')
  if #warnings == 0 then
    vim.notify('clang_tidy_analysis: no warnings in ' .. log_path, vim.log.levels.INFO)
  else
    vim.notify(('clang_tidy_analysis: %d warning(s) from %s'):format(#warnings, log_path), vim.log.levels.INFO)
  end
end

--- Compute warnings in new_log that are not in old_log; write diff to out_path and show in quickfix.
--- @param old_log string path to baseline log
--- @param new_log string path to new log
--- @param out_path string path for diff output (default: clang_tidy.diff.log in cwd)
function M.diff_logs(old_log, new_log, out_path)
  old_log = vim.fn.fnamemodify(old_log, ':p')
  new_log = vim.fn.fnamemodify(new_log, ':p')
  out_path = out_path or (vim.fn.getcwd() .. '/clang_tidy.diff.log')
  out_path = vim.fn.fnamemodify(out_path, ':p')

  local old_w, err_old = M.parse_log(old_log)
  if err_old then
    vim.notify('clang_tidy_analysis (old): ' .. err_old, vim.log.levels.ERROR)
    return
  end
  local new_w, err_new = M.parse_log(new_log)
  if err_new then
    vim.notify('clang_tidy_analysis (new): ' .. err_new, vim.log.levels.ERROR)
    return
  end

  local old_keys = {}
  for _, w in ipairs(old_w) do
    old_keys[w.key] = true
  end

  local diff_warnings = {}
  for _, w in ipairs(new_w) do
    if not old_keys[w.key] then
      table.insert(diff_warnings, w)
    end
  end

  -- Write diff log
  local out = io.open(out_path, 'w')
  if not out then
    vim.notify('clang_tidy_analysis: cannot write ' .. out_path, vim.log.levels.ERROR)
    return
  end
  for _, w in ipairs(diff_warnings) do
    for _, line in ipairs(w.raw_lines) do
      out:write(line, '\n')
    end
  end
  out:close()

  local qf = warnings_to_qflist(diff_warnings)
  vim.fn.setqflist(qf, 'r')
  vim.cmd('copen')
  vim.notify(
    ('clang_tidy_analysis: %d new warning(s) -> %s'):format(#diff_warnings, out_path),
    #diff_warnings > 0 and vim.log.levels.WARN or vim.log.levels.INFO
  )
end

-- User commands
vim.api.nvim_create_user_command('ClangTidyShowLog', function(opts)
  local path = opts.args
  if path == '' then
    path = nil
  end
  M.show_log(path)
end, {
  nargs = '?',
  desc = 'Parse clang_tidy.log (or given path) and show warnings in quickfix',
})

vim.api.nvim_create_user_command('ClangTidyDiff', function(opts)
  local args = vim.split(opts.args, '%s+', { plain = true })
  if #args < 2 then
    vim.notify('ClangTidyDiff: usage :ClangTidyDiff <old_log> <new_log> [out_path]', vim.log.levels.ERROR)
    return
  end
  local out_path = args[3] and args[3] ~= '' and args[3] or nil
  M.diff_logs(args[1], args[2], out_path)
end, {
  nargs = '+',
  desc = 'Diff two clang_tidy logs; show new warnings in quickfix and write to clang_tidy.diff.log (or third arg)',
})

return M
