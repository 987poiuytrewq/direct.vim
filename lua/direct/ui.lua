-- lua/direct/ui.lua -- notify plus the injectable prompt seam.
-- prompt() is the only place that may reach vim.fn.input; tests replace the
-- module function so a headless run can never block on an interactive prompt.

local M = {}

local function strip_traceback(message)
  local traceback = message:find('\nstack traceback:', 1, true)
  if traceback then message = message:sub(1, traceback - 1) end
  return message
end

function M.notify(msg, level, options)
  local message = tostring(msg or '')
  if message ~= '' and not message:match('^direct:') then
    message = 'direct: ' .. message
  end
  if options and options.ephemeral then
    local highlight = level == vim.log.levels.ERROR and 'ErrorMsg'
      or level == vim.log.levels.WARN and 'WarningMsg' or 'MoreMsg'
    return pcall(vim.api.nvim_echo, { { message, highlight } }, false, {})
  end
  local ok = pcall(vim.notify, message, level)
  if not ok then
    local highlight = level == vim.log.levels.ERROR and 'ErrorMsg' or 'WarningMsg'
    local echoed = pcall(vim.api.nvim_echo, { { message, highlight } }, true, {})
    if not echoed then
      pcall(vim.api.nvim_err_writeln, message)
    end
  end
end

-- report_error(action, err[, level]) turns a raised Lua error into one concise
-- user-facing message. Keep the cause's first line, but never expose an internal
-- traceback as part of a normal notification. The original error is returned so
-- callers of the public Lua API can still inspect it.
function M.error_message(action, err)
  action = tostring(action or 'complete the operation')
  local detail = strip_traceback(tostring(err or ''))
  local newline = detail:find('\n', 1, true)
  if newline then detail = detail:sub(1, newline - 1) end
  detail = detail:gsub('^%s*(.-)%s*$', '%1')
  -- Lua errors often start with an implementation filename and line number;
  -- those details are useful in the returned error, but distract in a notice.
  detail = detail:gsub('^.-:%d+: ', '')
  if detail == '' then detail = 'please try again' end
  return 'direct: Could not ' .. action .. ': ' .. detail
end

function M.report_error(action, err, level)
  M.notify(M.error_message(action, err), level or vim.log.levels.ERROR)
  return nil, err
end

-- inputsave/inputrestore must stay bracketed around the pcall so a failed input still restores prompt state.
function M.prompt(prompt, text, completion)
  vim.fn.inputsave()
  local ok, answer = pcall(vim.fn.input, prompt, text or '', completion or '')
  vim.fn.inputrestore()
  if not ok then
    error(answer, 0)
  end
  return answer
end

-- input(prompt, default, completion, on_confirm[, on_error]) runs vim.ui.input
-- through its callback API. It is intentionally separate from prompt():
-- callers cannot fall back to vim.fn.input if a UI backend is missing or fails.
function M.input(prompt, default, completion, on_confirm, on_error)
  if type(on_confirm) ~= 'function' then
    return nil, 'vim.ui.input requires a completion callback'
  end
  local completed = false
  local function settle(value)
    if completed then return end
    completed = true
    local ok, err = xpcall(function() on_confirm(value) end, debug.traceback)
    if not ok then
      if type(on_error) == 'function' then
        local reported, report_err = pcall(on_error, err)
        if not reported then
          M.report_error('handle the input error', report_err)
        end
      else
        M.report_error('complete the input', err)
      end
    end
  end
  local ok, err = pcall(vim.ui.input, {
    prompt = prompt,
    default = default or '',
    completion = completion or '',
  }, settle)
  if not ok then
    return nil, tostring(err)
  end
  return true
end

return M
