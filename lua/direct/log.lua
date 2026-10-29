-- lua/direct/log.lua -- raw and line-oriented log IO. History rewrites use an
-- exclusive same-directory temp, fsync, close, and atomic rename.

local M = {}
M.uv = vim.uv
local temp_sequence = 0

-- read_raw(path) -> bytes, nil, exists | nil, nil, false when absent | nil, err.
-- Unlike read(), this distinguishes an absent file from an unreadable one and
-- never normalizes bytes through Vim's line-oriented readfile().
function M.read_raw(path)
  local lst, lstat_err, lstat_code = M.uv.fs_lstat(path)
  if not lst then
    if lstat_code == 'ENOENT' then return nil, nil, false end
    return nil, tostring(lstat_err or lstat_code or 'lstat failed'), true
  end
  if lst.type ~= 'file' then
    return nil, 'history path is not a regular file', true
  end
  local fd, err, code = M.uv.fs_open(path, 'r', 0)
  if not fd then
    if code == 'ENOENT' then return nil, nil, false end
    return nil, tostring(err or code or 'open failed'), true
  end
  local stat, stat_err = M.uv.fs_fstat(fd)
  if not stat then
    M.uv.fs_close(fd)
    return nil, tostring(stat_err or 'stat failed'), true
  end
  local bytes, read_err
  if stat.size == 0 then
    bytes = ''
  else
    bytes, read_err = M.uv.fs_read(fd, stat.size, 0)
  end
  local close_ok, close_err = M.uv.fs_close(fd)
  if not bytes then return nil, tostring(read_err or 'read failed'), true end
  if #bytes ~= stat.size then return nil, 'short raw history read', true end
  if close_ok == nil or close_ok == false then
    return nil, tostring(close_err or 'close failed'), true
  end
  return bytes, nil, true
end

local function remove_temp(path)
  if path then pcall(M.uv.fs_unlink, path) end
end

-- write_raw_atomic(path, bytes) -> true | nil, err. `path` must name an owned
-- history file; the temp is always exclusive and on the same filesystem.
function M.write_raw_atomic(path, bytes)
  if type(bytes) ~= 'string' then
    return nil, 'log.write_raw_atomic: bytes must be a string'
  end
  local fd, temp_path, open_err
  for _ = 1, 100 do
    temp_sequence = temp_sequence + 1
    temp_path = string.format('%s.direct-tmp-%d-%d', path,
      M.uv.os_getpid(), temp_sequence)
    local code
    fd, open_err, code = M.uv.fs_open(temp_path, 'wx', 420)
    if fd then break end
    if code ~= 'EEXIST' then
      return nil, tostring(open_err or code or 'temp create failed')
    end
  end
  if not fd then
    return nil, tostring(open_err or 'could not allocate a unique temp file')
  end

  local offset, failure = 0, nil
  while offset < #bytes do
    local count, write_err = M.uv.fs_write(fd, bytes:sub(offset + 1), offset)
    if type(count) ~= 'number' or count <= 0 then
      failure = tostring(write_err or 'short write')
      break
    end
    offset = offset + count
  end
  if not failure then
    local synced, sync_err = M.uv.fs_fsync(fd)
    if synced == nil or synced == false then
      failure = tostring(sync_err or 'fsync failed')
    end
  end
  local closed, close_err = M.uv.fs_close(fd)
  if not failure and (closed == nil or closed == false) then
    failure = tostring(close_err or 'close failed')
  end
  if failure then
    remove_temp(temp_path)
    return nil, failure
  end

  local renamed, rename_err = M.uv.fs_rename(temp_path, path)
  if not renamed then
    remove_temp(temp_path)
    return nil, tostring(rename_err or 'rename failed')
  end
  return true
end

local function encode_lines(lines)
  if #lines == 0 then return '' end
  return table.concat(lines, '\n') .. '\n'
end

-- Overwrites the whole file atomically. Every line ends in LF, including the
-- history header and the final record.
function M.write(path, lines)
  if type(lines) ~= 'table' then
    return nil, 'log.write: lines must be a table'
  end
  for _, line in ipairs(lines) do
    if type(line) ~= 'string' or line:find('[\r\n]') then
      return nil, 'log.write: lines must be strings without line breaks'
    end
  end
  return M.write_raw_atomic(path, encode_lines(lines))
end

local function split_lines(bytes)
  local lines = {}
  if bytes == '' then return lines end
  local first = 1
  while first <= #bytes do
    local ending = bytes:find('\n', first, true)
    if not ending then
      lines[#lines + 1] = bytes:sub(first)
      break
    end
    lines[#lines + 1] = bytes:sub(first, ending - 1)
    first = ending + 1
  end
  return lines
end

function M.read(path)
  local bytes = M.read_raw(path)
  if type(bytes) ~= 'string' then
    return {}
  end
  return split_lines(bytes)
end

-- These convenience operations are retained for non-history users and tests;
-- history itself rewrites its complete validated record set atomically.
function M.push(path, line)
  if type(line) ~= 'string' or line:find('[\r\n]') then
    return nil, 'log.push: line must be a single string'
  end
  local lines = M.read(path)
  lines[#lines + 1] = line
  return M.write(path, lines)
end

function M.pop(path)
  local lines = M.read(path)
  if #lines == 0 then return nil end
  local line = table.remove(lines)
  local ok, err = M.write(path, lines)
  if not ok then return nil, err end
  return line
end

return M
