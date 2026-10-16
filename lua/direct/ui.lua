-- lua/direct/ui.lua -- notify plus the injectable prompt seam.
--
-- Responsibility (spec section 5 / D9): notify(msg, level) routes to vim.notify;
-- prompt(...) is the single injectable user-input seam. Business code must call
-- prompt through the module table so the harness's `with_prompt` can replace it
-- and vim.fn.input is never reached under `-l` (R1). This is the only place in
-- the plugin allowed to call vim.fn.input.

local M = {}

function M.notify(msg, level)
  vim.notify(msg, level)
end

-- prompt(prompt, text, completion) -> the user's answer (string).
-- The three calls are made in this order: inputsave, input, inputrestore. The
-- pcall only guarantees inputrestore runs, it does not change the order.
-- Tests replace this field (never vim.fn.input), so a headless run cannot
-- block on a real prompt.
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
