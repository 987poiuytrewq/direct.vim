-- SHA-256 over raw Lua string bytes. Used when Neovim's Vimscript sha256()
-- cannot accept strings containing NUL (Neovim 0.11).
local bit = require('bit')
local band, bnot, bxor = bit.band, bit.bnot, bit.bxor
local ror, rshift = bit.ror, bit.rshift
local MOD = 4294967296

local initial = {
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local constants = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function add(...)
  local sum = 0
  for index = 1, select('#', ...) do
    sum = (sum + select(index, ...)) % MOD
  end
  return sum
end

local function be32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256)
end

return function(input)
  assert(type(input) == 'string', 'sha256 expects a string')
  local bit_length = #input * 8
  local high_length = math.floor(bit_length / MOD)
  local low_length = bit_length % MOD
  local padding = (56 - ((#input + 1) % 64)) % 64
  local message = input .. '\128' .. string.rep('\0', padding)
    .. be32(high_length) .. be32(low_length)
  local hash = { unpack(initial) }

  for offset = 1, #message, 64 do
    local words = {}
    for index = 0, 15 do
      local at = offset + index * 4
      local a, b, c, d = message:byte(at, at + 3)
      words[index + 1] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for index = 17, 64 do
      local x = words[index - 15]
      local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
      local y = words[index - 2]
      local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
      words[index] = add(words[index - 16], s0, words[index - 7], s1)
    end

    local a, b, c, d, e, f, g, h = unpack(hash)
    for index = 1, 64 do
      local sum1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local choose = bxor(band(e, f), band(bnot(e), g))
      local temp1 = add(h, sum1, choose, constants[index], words[index])
      local sum0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local majority = bxor(band(a, b), band(a, c), band(b, c))
      local temp2 = add(sum0, majority)
      h, g, f = g, f, e
      e = add(d, temp1)
      d, c, b = c, b, a
      a = add(temp1, temp2)
    end
    hash[1], hash[2], hash[3], hash[4] = add(hash[1], a), add(hash[2], b), add(hash[3], c), add(hash[4], d)
    hash[5], hash[6], hash[7], hash[8] = add(hash[5], e), add(hash[6], f), add(hash[7], g), add(hash[8], h)
  end

  local digest = {}
  for index, word in ipairs(hash) do digest[index] = string.format('%08x', word) end
  return table.concat(digest)
end
