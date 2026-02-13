--- Clang-tidy log parser and Neovim integration.
--- Parses clang_tidy.log for "path:line:col: warning:" and shows in quickfix.
--- @module clang_tidy_analysis

local M = {}

local FIDGET_KEY = 'clang_tidy_analysis'

--- Report task progress via fidget.nvim if available (optional dependency).
local function fidget_notify(msg, level, opts)
  opts = opts or {}
  opts.key = opts.key or FIDGET_KEY
  local ok, fidget = pcall(require, 'fidget')
  if ok and fidget and fidget.notify then
    fidget.notify(msg, level or vim.log.levels.INFO, opts)
  end
end

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

--- Normalize a line from raw_lines for content comparison (strip path:line:col and line-number | prefix).
local function normalize_content_line(line)
  return (line:gsub('^[^:]*:%d+:%d*:?%s*', ''):gsub('^%s*%d+%s*|%s*', ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Content signature for a warning: message + normalized continuation lines (so same warning in renamed file matches).
local function content_signature(w)
  local parts = { w.message:match('^%s*(.-)%s*$') }
  for i = 2, #w.raw_lines do
    parts[i] = normalize_content_line(w.raw_lines[i])
  end
  return table.concat(parts, '\n')
end

--- Get changed line ranges (new file side) from git diff upstream_ref...HEAD.
--- Returns (ranges_by_file, repo_root) or (nil, nil) on error. ranges_by_file[rel_path] = { {start=N, count=M}, ... }.
--- @param upstream_ref string e.g. "upstream/main" or "origin/main"
--- @param cwd string working directory (git repo root or subdir)
--- @return table|nil ranges_by_file (key = path relative to repo root)
--- @return string|nil repo_root
local function get_changed_line_ranges(upstream_ref, cwd)
  local repo_root = vim.fn.trim(vim.fn.system({ 'git', 'rev-parse', '--show-toplevel' }) or '')
  if repo_root == '' or vim.v.shell_error ~= 0 then
    return nil, nil
  end
  -- Three-dot: changes in HEAD since branch point from upstream_ref (e.g. upstream/main)
  local diff_out = vim.fn.system({
    'git',
    'diff',
    upstream_ref .. '...HEAD',
    '--no-color',
    '-U0',
  })
  if vim.v.shell_error ~= 0 then
    return nil, nil
  end
  if not diff_out or diff_out == '' then
    return {}, repo_root
  end
  local ranges_by_file = {}
  local current_file_rel = nil
  for line in (diff_out .. '\n'):gmatch('(.-)\n') do
    local b_path = line:match('^diff %-%-git a/.+ b/(.+)$')
    if b_path then
      current_file_rel = b_path
      if current_file_rel ~= '' then
        ranges_by_file[current_file_rel] = ranges_by_file[current_file_rel] or {}
      end
    elseif current_file_rel and ranges_by_file[current_file_rel] then
      local new_start, new_count = line:match('^@@ .- %+(%d+),?(%d*) @@')
      if new_start then
        new_start = tonumber(new_start)
        new_count = (new_count == '' or new_count == '0') and 1 or tonumber(new_count)
        if new_start and new_count and new_count > 0 then
          table.insert(ranges_by_file[current_file_rel], { start = new_start, count = new_count })
        end
      end
    end
  end
  return ranges_by_file, repo_root
end

--- Get current branch upstream ref (e.g. upstream/main or origin/main) if set; nil otherwise.
local function get_default_upstream_ref()
  local ref = vim.fn.trim(vim.fn.system({ 'git', 'rev-parse', '--abbrev-ref', '@{upstream}' }) or '')
  if ref == '' or vim.v.shell_error ~= 0 then
    return nil
  end
  return ref
end

--- Check if (filename_abs, line_num) falls inside any changed range. filename can be absolute; repo_root used to get relative path.
local function is_line_in_changed_ranges(filename_abs, line_num, ranges_by_file, repo_root)
  if not ranges_by_file or not repo_root or repo_root == '' then
    return true
  end
  local path = filename_abs:gsub('\\', '/')
  repo_root = repo_root:gsub('\\', '/'):gsub('/$', '')
  local rel = path
  if path:sub(1, #repo_root) == repo_root then
    rel = path:sub(#repo_root + 2):gsub('^/', '')
  end
  local ranges = ranges_by_file[rel]
  if not ranges then
    -- Try with other path variants (e.g. rel might be packages/... from repo root)
    for rel_key, _ in pairs(ranges_by_file) do
      if rel:find(rel_key, 1, true) == 1 or rel_key:find(rel, 1, true) == 1 then
        ranges = ranges_by_file[rel_key]
        break
      end
    end
  end
  if not ranges then
    return false
  end
  for _, r in ipairs(ranges) do
    if line_num >= r.start and line_num < r.start + r.count then
      return true
    end
  end
  return false
end

--- Compute warnings in new_log that are not in old_log; write diff to out_path and show in quickfix.
--- Duplicates are removed by key (file:line:col:message) and by content (message + lines below), so renamed files match.
--- If upstream_ref is given, only warnings on lines changed since that ref (e.g. upstream/main) are kept.
--- @param old_log string? path to baseline log (default: clang_tidy.old.log in cwd)
--- @param new_log string? path to new log (default: clang_tidy.new.log in cwd)
--- @param out_path string? path for diff output (default: clang_tidy.diff.log in cwd)
--- @param upstream_ref string? if set, filter to warnings only in lines changed since upstream_ref...HEAD (e.g. "upstream/main")
function M.diff_logs(old_log, new_log, out_path, upstream_ref)
  local cwd = vim.fn.getcwd()
  old_log = (old_log and old_log ~= '') and vim.fn.fnamemodify(old_log, ':p') or (cwd .. '/clang_tidy.old.log')
  new_log = (new_log and new_log ~= '') and vim.fn.fnamemodify(new_log, ':p') or (cwd .. '/clang_tidy.new.log')
  out_path = out_path or (cwd .. '/clang_tidy.diff.log')
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
  local old_content = {}
  local old_messages = {}
  for _, w in ipairs(old_w) do
    old_keys[w.key] = true
    old_content[content_signature(w)] = true
    old_messages[w.message:match('^%s*(.-)%s*$')] = true
  end

  local diff_warnings = {}
  local debug_log = os.getenv('CLANG_TIDY_ANALYSIS_DEBUG') == '1'
  local stats = { by_key = 0, by_content = 0, by_message = 0, kept = 0 }
  --- For debug: short path (basename or rel) and truncated message.
  local function debug_label(w)
    local path = w.filename:gsub('\\', '/')
    local short_path = path:match('([^/]+)$') or path
    if #short_path > 40 then short_path = '...' .. short_path:sub(-37) end
    local msg_short = (w.message:match('^%s*(.-)%s*$') or w.message):sub(1, 52)
    if #msg_short >= 52 then msg_short = msg_short .. '...' end
    return ('%s:%d'):format(short_path, w.lnum), msg_short
  end
  for _, w in ipairs(new_w) do
    local msg_norm = w.message:match('^%s*(.-)%s*$')
    local seen_by_key = old_keys[w.key]
    local seen_by_content = old_content[content_signature(w)]
    local seen_by_message = old_messages[msg_norm]
    local decision
    if seen_by_key then
      stats.by_key = stats.by_key + 1
      decision = 'excluded:by_key'
    elseif seen_by_content then
      stats.by_content = stats.by_content + 1
      decision = 'excluded:by_content'
    elseif seen_by_message then
      stats.by_message = stats.by_message + 1
      decision = 'excluded:by_message'
    else
      stats.kept = stats.kept + 1
      decision = 'kept'
      table.insert(diff_warnings, w)
    end
    if debug_log then
      local loc, msg_short = debug_label(w)
      io.stderr:write(('[clang_tidy_analysis] %s | %s | %s\n'):format(loc, decision, msg_short))
    end
  end
  if debug_log then
    io.stderr:write(('[clang_tidy_analysis] --- summary: old=%d new=%d -> kept=%d (excluded: by_key=%d by_content=%d by_message=%d)\n')
      :format(#old_w, #new_w, stats.kept, stats.by_key, stats.by_content, stats.by_message))
  end

  -- Optional: keep only warnings on lines changed since upstream (default: current branch's @{upstream}, e.g. upstream/main)
  if not upstream_ref or upstream_ref == '' then
    upstream_ref = get_default_upstream_ref()
  end
  local ranges_by_file, repo_root
  if upstream_ref and upstream_ref ~= '' then
    ranges_by_file, repo_root = get_changed_line_ranges(upstream_ref, cwd)
    if not repo_root then
      vim.notify('clang_tidy_analysis: not a git repo or invalid upstream ref "' .. upstream_ref .. '"', vim.log.levels.ERROR)
      return
    end
    local filtered = {}
    for _, w in ipairs(diff_warnings) do
      local in_range = is_line_in_changed_ranges(w.filename, w.lnum, ranges_by_file, repo_root)
      if debug_log then
        local loc, msg_short = debug_label(w)
        io.stderr:write(('[clang_tidy_analysis] %s | %s | %s\n')
          :format(loc, in_range and 'in_changed_lines' or 'dropped:not_in_changed_lines', msg_short))
      end
      if in_range then
        table.insert(filtered, w)
      end
    end
    diff_warnings = filtered
    if debug_log then
      io.stderr:write(('[clang_tidy_analysis] --- after changed-lines filter (ref=%s): %d kept\n')
        :format(upstream_ref or '', #diff_warnings))
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

-- Clang-tidy stdout: "[2/3] Processing file /path/to/file.cpp." and "145881 warnings generated."
local CLANG_TIDY_PROGRESS_PATTERN = '^%[(%d+)/(%d+)%]%s+Processing file%s+(.-)%.?%s*$'
local CLANG_TIDY_SUMMARY_PATTERN = '^(%d+)%s+warning[s]?%s+generated%.%s*$'

--- Run clang-tidy on all *.cpp under folder and tee output to clang_tidy.old.log or clang_tidy.new.log.
--- Reports progress via fidget.nvim from "[N/M] Processing file ..." and "N warnings generated." in log output.
--- @param folder string directory to search (e.g. addon)
--- @param which string "old" or "new" -> clang_tidy.old.log or clang_tidy.new.log
--- @param build_dir string|nil compile_commands dir (default: build)
--- @param config_file string|nil path to .clang-tidy (default: .clang-tidy in cwd)
--- @param on_done function|nil callback(job_exit_code) when job exits
function M.generate(folder, which, build_dir, config_file, on_done)
  local cwd = vim.fn.getcwd()
  which = (which == 'old' or which == 'new') and which or 'new'
  build_dir = (build_dir and build_dir ~= '') and build_dir or 'build'
  config_file = (config_file and config_file ~= '') and config_file or '.clang-tidy'
  local out_log = cwd .. '/clang_tidy.' .. which .. '.log'
  -- Shell: clang-tidy on *.cpp, *.hpp, *.h so headers (e.g. naming in .hpp) are analyzed too.
  local find_exts = "find %s \\( -name '*.c*' -o -name '*.h*' \\)"
  local cmd = string.format(
    "clang-tidy --config-file=%s -p %s $(%s) 2>&1 | tee %s",
    vim.fn.shellescape(config_file),
    vim.fn.shellescape(build_dir),
    find_exts:format(vim.fn.shellescape(folder)),
    vim.fn.shellescape(out_log)
  )
  local task_label = ('clang-tidy %s (%s)'):format(which, folder)
  local fidget_key = FIDGET_KEY .. '_' .. which .. '_' .. folder:gsub('[^%w]', '_')
  local function update_fidget(msg, annote)
    fidget_notify(msg, vim.log.levels.INFO, { key = fidget_key, annote = annote or 'running…' })
  end
  update_fidget(task_label, 'running…')
  vim.notify(('clang_tidy_analysis: running clang-tidy on %s -> %s'):format(folder, out_log), vim.log.levels.INFO)
  vim.fn.jobstart(cmd, {
    cwd = cwd,
    shell = true,
    on_stdout = function(_, data, _)
      if not data then return end
      for _, line in ipairs(data) do
        line = type(line) == 'string' and line or ''
        local cur, total, file = line:match(CLANG_TIDY_PROGRESS_PATTERN)
        if cur and total and file then
          local short = file:match('([^/]+)$') or file
          update_fidget(('[%s/%s] %s'):format(cur, total, short), ('Processing %s'):format(short))
        else
          local n = line:match(CLANG_TIDY_SUMMARY_PATTERN)
          if n then
            update_fidget(('%s [%s/%s]'):format(task_label, n, n), ('%s warnings generated'):format(n))
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        fidget_notify(task_label, vim.log.levels.INFO, { key = fidget_key, annote = 'done' })
        vim.notify(('clang_tidy_analysis: wrote %s'):format(out_log), vim.log.levels.INFO)
      else
        fidget_notify(task_label, vim.log.levels.WARN, { key = fidget_key, annote = ('exit %s'):format(code) })
        vim.notify(('clang_tidy_analysis: command exited with %s (output still written to %s)'):format(code, out_log), vim.log.levels.WARN)
      end
      if type(on_done) == 'function' then
        on_done(code)
      end
    end,
  })
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
  -- 0 args: use clang_tidy.old.log and clang_tidy.new.log
  -- 1–3: old_log, new_log, out_path; 4th: upstream_ref (only show warnings on lines changed since that ref, e.g. upstream/main)
  local old_log = args[1] and args[1] ~= '' and args[1] or nil
  local new_log = args[2] and args[2] ~= '' and args[2] or nil
  local out_path = args[3] and args[3] ~= '' and args[3] or nil
  local upstream_ref = args[4] and args[4] ~= '' and args[4] or nil
  M.diff_logs(old_log, new_log, out_path, upstream_ref)
end, {
  nargs = '*',
  desc = 'Diff clang_tidy logs; optional 4th arg: upstream_ref (e.g. upstream/main) to keep only warnings on changed lines',
})

vim.api.nvim_create_user_command('ClangTidyGenerateOld', function(opts)
  local folder = opts.args:match('^%s*(.-)%s*$')
  if folder == '' then
    vim.notify('ClangTidyGenerateOld: usage :ClangTidyGenerateOld <folder> (e.g. addon)', vim.log.levels.ERROR)
    return
  end
  M.generate(folder, 'old')
end, {
  nargs = 1,
  desc = 'Run clang-tidy on folder (find folder -name "*.cpp") and write output to clang_tidy.old.log',
})

vim.api.nvim_create_user_command('ClangTidyGenerateNew', function(opts)
  local folder = opts.args:match('^%s*(.-)%s*$')
  if folder == '' then
    vim.notify('ClangTidyGenerateNew: usage :ClangTidyGenerateNew <folder> (e.g. addon)', vim.log.levels.ERROR)
    return
  end
  M.generate(folder, 'new')
end, {
  nargs = 1,
  desc = 'Run clang-tidy on folder (find folder -name "*.cpp") and write output to clang_tidy.new.log',
})

--- Generate new log then run diff (uses existing clang_tidy.old.log).
vim.api.nvim_create_user_command('ClangTidyGenerateNewDiff', function(opts)
  local folder = opts.args:match('^%s*(.-)%s*$')
  if folder == '' then
    vim.notify('ClangTidyGenerateNewDiff: usage :ClangTidyGenerateNewDiff <folder> (e.g. addon)', vim.log.levels.ERROR)
    return
  end
  fidget_notify('ClangTidyGenerateNewDiff: generating new then diff…', vim.log.levels.INFO, { annote = 'running…' })
  M.generate(folder, 'new', nil, nil, function()
    M.diff_logs(nil, nil, nil)
    fidget_notify('ClangTidyGenerateNewDiff: done', vim.log.levels.INFO, { annote = 'done' })
  end)
end, {
  nargs = 1,
  desc = 'Run ClangTidyGenerateNew <folder> then ClangTidyDiff (needs clang_tidy.old.log already)',
})

--- Run generate-diff: optionally checkout branch and generate old, then generate new and diff.
--- If branch is not given, opens vim.ui.select to pick a branch.
local function run_generate_diff(folder, branch)
  local cwd = vim.fn.getcwd()
  local prev_branch = vim.fn.trim(vim.fn.system({ 'git', 'rev-parse', '--abbrev-ref', 'HEAD' }) or '')
  if prev_branch == '' or vim.v.shell_error ~= 0 then
    vim.notify('ClangTidyGenerateDiff: not in a git repo or could not get current branch', vim.log.levels.ERROR)
    return
  end
  local function do_checkout_then_old(branch_to_use)
    branch_to_use = branch_to_use or branch
    if not branch_to_use or branch_to_use == '' then return end
    fidget_notify(('ClangTidyGenerateDiff: checkout %s…'):format(branch_to_use), vim.log.levels.INFO, { annote = 'running…' })
    vim.fn.jobstart({ 'git', 'checkout', branch_to_use }, {
      cwd = cwd,
      on_exit = function(_, checkout_code)
        if checkout_code ~= 0 then
          fidget_notify(('ClangTidyGenerateDiff: git checkout %s failed'):format(branch_to_use), vim.log.levels.ERROR, { annote = 'failed' })
          vim.notify(('ClangTidyGenerateDiff: git checkout %s failed'):format(branch_to_use), vim.log.levels.ERROR)
          return
        end
        M.generate(folder, 'old', nil, nil, function()
          vim.fn.jobstart({ 'git', 'checkout', prev_branch }, {
            cwd = cwd,
            on_exit = function(_, back_code)
              if back_code ~= 0 then
                fidget_notify('ClangTidyGenerateDiff: git checkout back failed', vim.log.levels.ERROR, { annote = 'failed' })
                vim.notify('ClangTidyGenerateDiff: failed to checkout back to ' .. prev_branch, vim.log.levels.ERROR)
                return
              end
              M.generate(folder, 'new', nil, nil, function()
                M.diff_logs(nil, nil, nil)
                fidget_notify('ClangTidyGenerateDiff: done', vim.log.levels.INFO, { annote = 'done' })
              end)
            end,
          })
        end)
      end,
    })
  end
  if branch and branch ~= '' then
    do_checkout_then_old(branch)
    return
  end
  local raw = vim.fn.system({ 'git', 'for-each-ref', '--format=%(refname:short)', 'refs/heads/' })
  if not raw or raw == '' or vim.v.shell_error ~= 0 then
    vim.notify('ClangTidyGenerateDiff: could not list branches', vim.log.levels.ERROR)
    return
  end
  local branches = {}
  for line in (raw:gmatch('[^\r\n]+')) do
    line = line:match('^%s*(.-)%s*$')
    if line ~= '' then table.insert(branches, line) end
  end
  if #branches == 0 then
    vim.notify('ClangTidyGenerateDiff: no branches found', vim.log.levels.ERROR)
    return
  end
  vim.ui.select(branches, {
    prompt = 'Select branch for old log (baseline):',
    format_item = function(item) return item end,
  }, function(choice)
    if not choice or choice == '' then return end
    do_checkout_then_old()
  end)
end

vim.api.nvim_create_user_command('ClangTidyGenerateDiff', function(opts)
  local args = vim.split(opts.args, '%s+', { plain = true })
  if #args < 1 or args[1] == '' then
    vim.notify('ClangTidyGenerateDiff: usage :ClangTidyGenerateDiff <folder> [branch] (e.g. addon or addon main)', vim.log.levels.ERROR)
    return
  end
  local folder = args[1]
  local branch = (args[2] and args[2] ~= '') and args[2] or nil
  run_generate_diff(folder, branch)
end, {
  nargs = '*',
  desc = 'Generate old on <branch> (or pick from GUI), then new on current branch and diff. Usage: <folder> [branch]',
})

return M
