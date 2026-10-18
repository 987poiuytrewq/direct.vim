-- lua/direct/log.lua -- append-only whole-file line log; reads and rewrites the
-- whole file (history logs are kilobytes). A missing or unreadable log reads as
-- empty -- E484 never escapes -- and the path is always supplied by the caller.

local M = {}

function M.read(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= 'table' then
    return {}
  end
  return lines
end

-- A non-string line is rejected before any write, so a stray nil cannot append a blank entry.
function M.push(path, line)
  if type(line) ~= 'string' then
    return nil, 'log.push: line must be a string'
  end
  local ok, err = pcall(vim.fn.writefile, { line }, path, 'a')
  if not ok then
    return nil, tostring(err)
  end
  return true
end

-- nil means the log was empty or missing; a write failure is nil, err.
function M.pop(path)
  local lines = M.read(path)
  if #lines == 0 then
    return nil
  end
  local line = table.remove(lines)
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return nil, tostring(err)
  end
  return line
end

-- Overwrites the whole file; the caller controls the first line (the history marker).
function M.write(path, lines)
  if type(lines) ~= 'table' then
    return nil, 'log.write: lines must be a table'
  end
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return nil, tostring(err)
  end
  return true
end

function M.clear(path)
  return M.write(path, {})
end

return M
