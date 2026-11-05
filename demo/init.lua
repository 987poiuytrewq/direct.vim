-- Minimal, predictable Neovim setup for the scripted terminal demos.
vim.opt.runtimepath:prepend(vim.env.DIRECT_DEMO_REPO)
vim.o.mouse = 'a'
vim.o.number = false
vim.o.relativenumber = false
vim.o.showmode = true
vim.o.termguicolors = true
vim.o.shiftwidth = 2
vim.o.expandtab = true
vim.opt.wildignore:append('.git')

require('direct').setup({
  map_default_keys = true,
  show_hidden = true,
  respect_gitignore = true,
  indent_size = 2,
  show_folder_icons = true,
  show_file_icons = true,
  git = { enabled = true, show_symbols = true, show_deleted = true },
})
