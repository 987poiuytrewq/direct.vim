-- lua/direct/ui.lua -- notify plus the injectable prompt seam.
-- prompt() is the only place that may reach vim.fn.input; tests replace the
-- module function so a headless run can never block on an interactive prompt.

local M = {}

function M.notify(msg, level)
  vim.notify(msg, level)
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
          M.notify('direct: input error handler failed: ' .. tostring(report_err),
            vim.log.levels.ERROR)
        end
      else
        M.notify('direct: input callback failed: ' .. tostring(err),
          vim.log.levels.ERROR)
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
