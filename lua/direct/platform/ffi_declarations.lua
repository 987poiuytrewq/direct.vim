-- Load LuaJIT FFI declarations from a header adjacent to the requesting module.
-- These files contain declarations only; they are read by ffi.cdef, not compiled.
local M = {}

function M.load(ffi, source, header, marker_type)
  local module_path = tostring(source):gsub('^@', '')
  module_path = vim.fn.fnamemodify(module_path, ':p')
  local header_path = vim.fs.joinpath(vim.fs.dirname(module_path), header)
  local ok, lines = pcall(vim.fn.readfile, header_path)
  if not ok or #lines == 0 then return nil, 'could not read FFI declarations: ' .. header_path end
  local declared, declaration_err = pcall(ffi.cdef, table.concat(lines, '\n'))
  if declared or (marker_type and pcall(ffi.typeof, marker_type)) then return true end
  return nil, tostring(declaration_err)
end

return M
