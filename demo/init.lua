-- Neovim setup for the scripted demo tour. It aims to look like a typical
-- setup: kickstart.nvim's options, plus the plugins most configs have
-- (catppuccin, lualine, bufferline and nvim-web-devicons). demo.sh downloads
-- those into demo/.plugins; without them the demo falls back to a plain look.
vim.opt.runtimepath:prepend(vim.env.DIRECT_DEMO_REPO)

local plugin_dir = vim.env.DIRECT_DEMO_PLUGINS
if plugin_dir and plugin_dir ~= '' then
  for _, name in ipairs({ 'catppuccin', 'nvim-web-devicons', 'lualine.nvim', 'bufferline.nvim' }) do
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

if not pcall(vim.cmd.colorscheme, 'catppuccin-mocha') then
  vim.o.background = 'dark'
  vim.cmd.colorscheme('default')
end

require('direct').setup({
  map_default_keys = true,
  show_hidden = true,
  respect_gitignore = true,
  -- Keep this tour's scripted directory navigation stable. The interactive
  -- default is on; collapse behavior is covered separately by the specs.
  collapse_single_entry_directories = false,
  indent_size = 2,
  show_folder_icons = true,
  show_file_icons = true,
  -- A renamed tracked file would otherwise leave a "deleted" row behind,
  -- which clutters the rename scenes.
  git = { enabled = true, show_symbols = true, show_deleted = false },
})

-- The fixture lives in a temporary directory; show it as ~/my-plugin.
-- Resolve links first: on macOS the temporary directory is a link
-- (/var -> /private/var), and buffer names use the resolved path.
local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

local root = real(vim.env.DIRECT_DEMO_WORKSPACE or vim.fn.getcwd())
local display_root = '~/' .. vim.fs.basename(root)

function _G.DemoStatus()
  local name = real(vim.api.nvim_buf_get_name(0))
  if name == root or name:sub(1, #root + 1) == root .. '/' then
    return display_root .. name:sub(#root + 1)
  end
  return name
end

-- Show paths in messages relative to the working directory, which demo.sh
-- sets to the project, as a user working in it would see them.
local function relative_paths(text)
  for _, dir in ipairs({ real(vim.fn.getcwd()), vim.fs.normalize(vim.fn.getcwd()) }) do
    text = text:gsub(vim.pesc(dir) .. '/?', '')
  end
  return text
end

-- Keep messages on one line, with short paths. A message wider than the
-- screen would stop Neovim at a "Press ENTER" prompt mid-recording.
local notify = vim.notify
vim.notify = function(message, level, opts)
  message = relative_paths(tostring(message)):gsub('\n.*', '')
  local width = vim.o.columns - 15
  if vim.fn.strdisplaywidth(message) > width then
    message = vim.fn.strcharpart(message, 0, width - 1) .. '…'
  end
  return notify(message, level, opts)
end

-- After a prompt, Neovim continues the next message on the prompt's line
-- ("Paste as: advancedPasted into examples/"). Redraw before passing the
-- answer on, so the message that follows starts on a clear line.
local ui_input = vim.ui.input
vim.ui.input = function(opts, on_confirm)
  return ui_input(opts, function(value)
    vim.cmd.redraw()
    on_confirm(value)
  end)
end

local has_lualine, lualine = pcall(require, 'lualine')
if has_lualine then
  lualine.setup({
    options = { globalstatus = true },
    sections = {
      lualine_b = { 'branch' },
      -- A function, not a 'v:lua...' string: lualine reads strings that
      -- start with 'v:' as Vim variables, which fails on every redraw and
      -- leaves the status line empty.
      lualine_c = { _G.DemoStatus },
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
      -- Name listings after their directory, with a trailing separator.
      name_formatter = function(buf)
        if vim.fn.isdirectory(buf.path) == 0 then
          return buf.name
        end
        local name = vim.fs.basename(vim.fs.normalize(buf.path))
        return name ~= '' and name .. '/' or buf.name
      end,
    },
  })
end

-- DemoCaption(title, keys) shows a caption card near the bottom of the
-- screen: the title in bold, and under it room for the keys the scene uses
-- (separated by two spaces in `keys`). Each key cap appears the moment its
-- first key reaches Neovim (see the vim.on_key handler below), so the caps
-- keep exact time with the typing; the GIF has no keystroke overlay, so this
-- is how it shows what's pressed. The card is sized for all of its keys up
-- front, so it doesn't grow as they appear. With `show_all`, every cap shows
-- at once. An empty title hides the card. drive.expect calls this with
-- `nvim --server ... --remote-expr`, so captions never appear as keystrokes.
local function colour(group, attr)
  return vim.api.nvim_get_hl(0, { name = group, link = false })[attr]
end

local function set_caption_colours()
  local accent = colour('Function', 'fg') or 0x7aa2f7
  local normal_bg = colour('Normal', 'bg') or 0x1a1b26
  local card_bg = colour('NormalFloat', 'bg') or colour('Pmenu', 'bg') or normal_bg
  local key_fg = colour('String', 'fg') or 0x9ece6a
  local key_bg = colour('Visual', 'bg') or colour('CursorLine', 'bg') or normal_bg
  vim.api.nvim_set_hl(0, 'DemoCaption', { bg = card_bg })
  vim.api.nvim_set_hl(0, 'DemoCaptionBorder', { fg = accent, bg = card_bg })
  vim.api.nvim_set_hl(0, 'DemoCaptionTitle', { fg = accent, bg = card_bg, bold = true })
  vim.api.nvim_set_hl(0, 'DemoCaptionKey', { fg = key_fg, bg = key_bg, bold = true })
  -- The key just typed stands out from the ones before it.
  vim.api.nvim_set_hl(0, 'DemoCaptionKeyNew', { fg = card_bg, bg = accent, bold = true })
end
set_caption_colours()

local caption = {
  buf = nil,
  win = nil,
  ns = vim.api.nvim_create_namespace('demo_caption'),
  keys = {},  -- the scene's keys
  shown = 0,  -- how many of them have been typed so far
  rest = '',  -- keys of the current cap still to arrive
}
local PAD = 3

local function draw_caption()
  local title = caption.title
  local pad = string.rep(' ', PAD)

  -- Each typed key becomes a cap with a space of padding on either side,
  -- and two spaces between caps. Keys not typed yet leave the line blank.
  local key_line, spans = '', {}
  for i = 1, caption.shown do
    if key_line ~= '' then
      key_line = key_line .. '  '
    end
    local start = #key_line
    key_line = key_line .. ' ' .. caption.keys[i] .. ' '
    spans[#spans + 1] = { start, #key_line, i == caption.shown }
  end

  local lines = { '', pad .. title }
  if #caption.keys > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = pad .. key_line
  end
  lines[#lines + 1] = ''

  vim.api.nvim_buf_set_lines(caption.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(caption.buf, caption.ns, 0, -1)
  vim.hl.range(caption.buf, caption.ns, 'DemoCaptionTitle', { 1, PAD }, { 1, PAD + #title })
  for _, span in ipairs(spans) do
    vim.hl.range(caption.buf, caption.ns, span[3] and 'DemoCaptionKeyNew' or 'DemoCaptionKey',
      { 3, PAD + span[1] }, { 3, PAD + span[2] })
  end
  vim.cmd.redraw()
end

function _G.DemoCaption(title, keys, show_all)
  if caption.win and vim.api.nvim_win_is_valid(caption.win) then
    vim.api.nvim_win_close(caption.win, true)
  end
  caption.win = nil
  if not title or title == '' then
    vim.cmd.redraw()
    return true
  end
  if not (caption.buf and vim.api.nvim_buf_is_valid(caption.buf)) then
    caption.buf = vim.api.nvim_create_buf(false, true)
  end

  caption.title = title
  caption.keys = vim.tbl_filter(function(key)
    return key ~= ''
  end, vim.split(keys or '', '%s%s+'))
  caption.shown = show_all and #caption.keys or 0
  caption.rest = ''

  -- Size the card for the title and all of its keys.
  local all_keys = ''
  for _, key in ipairs(caption.keys) do
    all_keys = all_keys .. (all_keys == '' and '' or '  ') .. ' ' .. key .. ' '
  end
  local width = math.max(vim.fn.strdisplaywidth(title), vim.fn.strdisplaywidth(all_keys))
    + PAD * 2
  local height = #caption.keys > 0 and 5 or 3

  caption.win = vim.api.nvim_open_win(caption.buf, false, {
    relative = 'editor',
    row = vim.o.lines - vim.o.cmdheight - height - 4,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    focusable = false,
    zindex = 200,
  })
  vim.wo[caption.win].winhighlight = 'Normal:DemoCaption,FloatBorder:DemoCaptionBorder'
  draw_caption()
  return true
end

-- Reveal each cap as its keys are typed. A cap is a short key sequence, such
-- as "/sc", "zo" or "Ctrl-u". The next cap appears when its first key
-- arrives; its remaining keys are then consumed, so the "c" in "/sc" can't
-- reveal a following "cw" early. A cap that starts with / or : also consumes
-- the Enter that runs it, so that Enter can't reveal a following "Enter" cap.
-- Other keys, such as typed text, are ignored.
local CAP_KEYS = { Esc = '\27', Enter = '\r', ['Ctrl-r'] = '\18', ['Ctrl-u'] = '\21' }

local function cap_bytes(cap)
  if CAP_KEYS[cap] then
    return CAP_KEYS[cap]
  end
  local first = cap:sub(1, 1)
  return (first == '/' or first == ':') and cap .. '\r' or cap
end

vim.on_key(function(_, typed)
  if not typed or typed == '' or not (caption.win and vim.api.nvim_win_is_valid(caption.win)) then
    return
  end
  if caption.rest ~= '' then
    if caption.rest:sub(1, #typed) == typed then
      caption.rest = caption.rest:sub(#typed + 1)
      return
    end
    caption.rest = ''
  end
  local next_cap = caption.keys[caption.shown + 1]
  if not next_cap then
    return
  end
  local bytes = cap_bytes(next_cap)
  if bytes:sub(1, #typed) == typed then
    caption.shown = caption.shown + 1
    caption.rest = bytes:sub(#typed + 1)
    -- Drawing changes a buffer, which isn't allowed inside on_key.
    vim.schedule(draw_caption)
  end
end)
