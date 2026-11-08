local version = vim.version()

if version.major == 0 and version.minor < 12 then
  io.stderr:write('Neovim >= 0.12 is required\n')
  os.exit(1)
end
