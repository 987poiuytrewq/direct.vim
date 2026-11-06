-- Neovim setup for the scripted demo tour. It aims to look like a typical
-- setup: kickstart.nvim's options, plus the plugins most configs have
-- (tokyonight, lualine, bufferline and nvim-web-devicons). demo.sh downloads
-- those into demo/.plugins; without them the demo falls back to a plain look.
vim.opt.runtimepath:prepend(vim.env.DIRECT_DEMO_REPO)

local plugin_dir = vim.env.DIRECT_DEMO_PLUGINS
if plugin_dir and plugin_dir ~= '' then
  for _, name in ipairs({ 'tokyonight.nvim', 'nvim-web-devicons', 'lualine.nvim', 'bufferline.nvim' }) do
    local path = plugin_dir .. '/' .. name
    if vim.uv.fs_stat(path) then
      vim.opt.runtimepath:append(path)
    end
  end
end

-- Options: the kickstart.nvim baseline.
vim.o.termguicolors = true
vim.o.mouse = 'a'
vim.o.number = true
vim.o.signcolumn = 'yes'
vim.o.cursorline = true
vim.o.scrolloff = 10
vim.o.showmode = false -- the status line shows the mode
vim.o.laststatus = 3
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.hlsearch = false
vim.o.breakindent = true
-- Show :s results live in the listing while the command is typed.
vim.o.inccommand = 'nosplit'
vim.o.fillchars = 'eob: '
vim.o.shortmess = vim.o.shortmess .. 'sI'
-- When several messages arrive at once (a delete reports "Yanked" and then
-- "Removed"), show them briefly instead of stopping at "Press ENTER".
vim.o.messagesopt = 'wait:800,history:500'
vim.o.shiftwidth = 2
vim.o.expandtab = true
vim.opt.wildignore:append('.git')

if not pcall(vim.cmd.colorscheme, 'tokyonight-night') then
  vim.o.background = 'dark'
  vim.cmd.colorscheme('default')
end

require('direct').setup({
  map_default_keys = true,
  show_hidden = true,
  respect_gitignore = true,
  indent_size = 2,
  show_folder_icons = true,
  show_file_icons = true,
  -- A renamed tracked file would otherwise leave a "deleted" row behind,
  -- which clutters the rename scenes.
  git = { enabled = true, show_symbols = true, show_deleted = false },
})

-- The fixture lives in a temporary directory; show it as ~/my-plugin.
local root = vim.fs.normalize(vim.env.DIRECT_DEMO_WORKSPACE or vim.fn.getcwd())
local display_root = '~/' .. vim.fs.basename(root)

local function display_path(path)
  return (path:gsub(vim.pesc(root), display_root))
end

function _G.DemoStatus()
  return display_path(vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
end

-- Keep messages on one line, with short paths. A message wider than the
-- screen would stop Neovim at a "Press ENTER" prompt mid-recording.
local notify = vim.notify
vim.notify = function(message, level, opts)
  message = display_path(tostring(message)):gsub('\n.*', '')
  local width = vim.o.columns - 15
  if vim.fn.strdisplaywidth(message) > width then
    message = vim.fn.strcharpart(message, 0, width - 1) .. '…'
  end
  return notify(message, level, opts)
end

local has_lualine, lualine = pcall(require, 'lualine')
if has_lualine then
  lualine.setup({
    options = { globalstatus = true },
    sections = {
      lualine_b = { 'branch' },
      lualine_c = { { 'v:lua.DemoStatus()' } },
      lualine_x = { { function() return 'direct.vim' end } },
      lualine_y = {},
      lualine_z = {},
    },
  })
else
  vim.o.statusline = '  %{v:lua.DemoStatus()}%=direct.vim  '
end

local has_bufferline, bufferline = pcall(require, 'bufferline')
if has_bufferline then
  bufferline.setup({
    options = {
      always_show_bufferline = true,
      show_buffer_close_icons = false,
      show_close_icon = false,
      -- Listings are named after their directory, which ends in a separator.
      name_formatter = function(buf)
        local name = vim.fs.basename(vim.fs.normalize(buf.path))
        return name ~= '' and name .. '/' or buf.name
      end,
    },
  })
end

-- DemoCaption(text) shows a caption near the bottom of the screen; an empty
-- text hides it. drive.expect calls it with `nvim --server ... --remote-expr`,
-- so captions never appear as keystrokes.
local function set_caption_colours()
  local accent = vim.api.nvim_get_hl(0, { name = 'Function', link = false }).fg or 0x7aa2f7
  local dark = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg or 0x1a1b26
  vim.api.nvim_set_hl(0, 'DemoCaption', { fg = dark, bg = accent, bold = true })
  vim.api.nvim_set_hl(0, 'DemoCaptionBorder', { fg = accent })
end
set_caption_colours()

local caption = { buf = nil, win = nil }

function _G.DemoCaption(text)
  if caption.win and vim.api.nvim_win_is_valid(caption.win) then
    vim.api.nvim_win_close(caption.win, true)
  end
  caption.win = nil
  if text and text ~= '' then
    if not (caption.buf and vim.api.nvim_buf_is_valid(caption.buf)) then
      caption.buf = vim.api.nvim_create_buf(false, true)
    end
    local line = '  ' .. text .. '  '
    vim.api.nvim_buf_set_lines(caption.buf, 0, -1, false, { line })
    local width = vim.fn.strdisplaywidth(line)
    caption.win = vim.api.nvim_open_win(caption.buf, false, {
      relative = 'editor',
      row = vim.o.lines - vim.o.cmdheight - 5,
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = 1,
      style = 'minimal',
      border = 'rounded',
      focusable = false,
      zindex = 200,
    })
    vim.wo[caption.win].winhighlight = 'Normal:DemoCaption,FloatBorder:DemoCaptionBorder'
  end
  vim.cmd.redraw()
  return true
end
