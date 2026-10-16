-- lua/direct/log.lua -- append-only whole-file line log.
--
-- Responsibility (spec section 5 / D12): push / pop / clear over a line file.
-- The file is read and rewritten whole because history logs are kilobytes. This
-- module does not parse action lines and never raises E484 for a missing file --
-- a missing or unreadable log is treated as empty.
--
-- Signature: the path of the line file is passed by the caller
-- (`log.push(undo_path, line)`), keeping this module ignorant of XDG layout.

local M = {}

-- read(path) -> string array. A missing/unreadable file is `{}` (D12); the
-- filereadable guard plus pcall is what keeps readfile's E484 out of the suite.
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

-- push(path, line) -> true | nil, err. Appends one line, creating the file.
-- A non-string line is rejected before any write so a stray nil cannot append
-- a blank file entry (B4).
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

-- pop(path) -> line | nil | nil, err. Removes and returns the last line;
-- returns nil when the log is empty or missing (change nothing). Callers
-- distinguish that from a write failure by the second return value.
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

-- write(path, lines) -> true | nil, err. Overwrites the whole file with `lines`
-- (a list of strings), creating it when absent. This is the generic whole-file
-- write for a caller that must control the FIRST line -- the history version
-- marker (T-017/D18) -- instead of appending to or reimplementing the
-- pcall-guarded writefile. A non-table argument is rejected before any write.
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

-- clear(path) -> true | nil, err. Empties the log in place, creating it when
-- absent so a subsequent read sees an empty, existing file.
function M.clear(path)
  return M.write(path, {})
end

return M
