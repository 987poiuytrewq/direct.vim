local version = vim.version()

if version.major == 0 and (version.minor < 11
    or (version.minor == 11 and version.patch < 7)) then
  io.stderr:write('Neovim >= 0.11.7 is required\n')
  os.exit(1)
end
