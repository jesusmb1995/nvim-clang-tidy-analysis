#!/usr/bin/env nvim
-- Run: CLANG_TIDY_ANALYSIS_DEBUG=1 nvim -l test_diff.lua
-- Or from embed pkg: CLANG_TIDY_ANALYSIS_DEBUG=1 nvim -l /home/jberlanga/Code/clang_tidy_analysis/test_diff.lua
local embed_cwd = '/luksmap/Code/qvac/packages/qvac-lib-infer-llamacpp-embed'
local plugin_rtp = '/home/jberlanga/Code/clang_tidy_analysis'
vim.opt.rtp:prepend(plugin_rtp)
vim.fn.chdir(embed_cwd)
local M = require('clang_tidy_analysis')
local old_log = embed_cwd .. '/clang_tidy.old.log'
local new_log = embed_cwd .. '/clang_tidy.new.log'
local out_path = embed_cwd .. '/clang_tidy.diff.log'
-- No upstream_ref so we don't filter by changed lines
M.diff_logs(old_log, new_log, out_path, nil)
io.stderr:write('Done. Check stderr for [clang_tidy_analysis] debug line.\n')
vim.cmd('quit')
