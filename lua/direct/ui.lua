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

return M
