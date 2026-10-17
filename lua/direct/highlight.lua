-- Filename highlights for direct listing rows.
-- Language membership is a static GitHub Innovation Graph 2026Q1 snapshot;
-- filename detection itself is delegated to Neovim and never reads file data.

local M = {}

local languages = {
  { name = 'JavaScript', filetype = 'javascript', probe = 'sample.js', group = 'DirectLangJavaScript' },
  { name = 'Python', filetype = 'python', probe = 'sample.py', group = 'DirectLangPython' },
  { name = 'TypeScript', filetype = 'typescript', probe = 'sample.ts', group = 'DirectLangTypeScript' },
  { name = 'Shell', filetype = 'sh', probe = 'sample.sh', group = 'DirectLangShell' },
  { name = 'Dockerfile', filetype = 'dockerfile', probe = 'Dockerfile', group = 'DirectLangDockerfile' },
  { name = 'Java', filetype = 'java', probe = 'sample.java', group = 'DirectLangJava' },
  { name = 'C++', filetype = 'cpp', probe = 'sample.cpp', group = 'DirectLangCpp' },
  { name = 'C', filetype = 'c', probe = 'sample.c', group = 'DirectLangC' },
  { name = 'Makefile', filetype = 'make', probe = 'Makefile', group = 'DirectLangMakefile' },
  { name = 'Batchfile', filetype = 'dosbatch', probe = 'sample.bat', group = 'DirectLangBatchfile' },
  { name = 'C#', filetype = 'cs', probe = 'sample.cs', group = 'DirectLangCSharp' },
  { name = 'PHP', filetype = 'php', probe = 'sample.php', group = 'DirectLangPHP' },
  { name = 'CMake', filetype = 'cmake', probe = 'CMakeLists.txt', group = 'DirectLangCMake' },
  { name = 'PowerShell', filetype = 'ps1', probe = 'sample.ps1', group = 'DirectLangPowerShell' },
  { name = 'Kotlin', filetype = 'kotlin', probe = 'sample.kt', group = 'DirectLangKotlin' },
  { name = 'Ruby', filetype = 'ruby', probe = 'sample.rb', group = 'DirectLangRuby' },
  { name = 'Go', filetype = 'go', probe = 'sample.go', group = 'DirectLangGo' },
  { name = 'Swift', filetype = 'swift', probe = 'sample.swift', group = 'DirectLangSwift' },
  { name = 'Rust', filetype = 'rust', probe = 'sample.rs', group = 'DirectLangRust' },
}

local language_by_filetype = {}
for _, language in ipairs(languages) do
  language_by_filetype[language.filetype] = language.group
end

local special_names = {
  Makefile = true,
  GNUmakefile = true,
  ['CMakeLists.txt'] = true,
  Rakefile = true,
  justfile = true,
  Dockerfile = true,
  Containerfile = true,
  Jenkinsfile = true,
  Vagrantfile = true,
  ['README.md'] = true,
  LICENSE = true,
  CODEOWNERS = true,
  Gemfile = true,
}

local namespace = vim.api.nvim_create_namespace('direct-listing-highlights')

local function define_groups()
  vim.api.nvim_set_hl(0, 'DirectSpecialFile', { default = true, link = 'Special' })
  for _, language in ipairs(languages) do
    vim.api.nvim_set_hl(0, language.group, {
      default = true,
      link = 'Type',
    })
  end
end

local function row_highlight(line)
  local indent, name = line:match('^(%s*)(.*)$')
  if not name or name == '' or name:sub(-1) == '/' or name:sub(1, 1) == '.' then
    return nil
  end
  if special_names[name] then
    return 'DirectSpecialFile', #indent, #indent + #name
  end
  local filetype = vim.filetype.match({ filename = name })
  local group = filetype and language_by_filetype[filetype]
  if group then
    return group, #indent, #indent + #name
  end
  return nil
end

-- Recompute after a render operation only; no text-change autocmd is installed.
function M.render(bufnr)
  define_groups()
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local group, start_col, end_col = row_highlight(line)
    if group then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, start_col, {
        end_col = end_col,
        hl_group = group,
      })
    end
  end
end

-- Private read-only test seam for checking the immutable snapshot table.
function M._languages_for_test()
  return vim.deepcopy(languages)
end

return M
