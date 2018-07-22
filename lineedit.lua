local T = require'thread'
local loop = require'loop'
local D = require'util'
D.prepend_thread_names = false
D.prepend_timestamps = false
local buffer = require'buffer'
local O = require'o'
local unicode = require'unicode'



local ANSIParser = O()

ANSIParser.keyseqs = {
  ["\004"] = "EOF",
  ["\008"] = "Backspace",
  ["\009"] = "Tab",
  ["\010"] = "Enter",
  ["\023"] = "Ctrl-W", -- or Alt-Backspace
  ["\027"] = 1,
  ["\027b"] = "Alt-Left",
  ["\027f"] = "Alt-Right",
  ["\027\027"] = 2,
  ["\027\027[A"] = "Alt-Up",
  ["\027\027[B"] = "Alt-Down",
  ["\027\027[C"] = "Alt-Right",
  ["\027\027[D"] = "Alt-Left",
  ["\027O"] = 1,
  ["\027Oa"] = "Ctrl-Up",
  ["\027Ob"] = "Ctrl-Down",
  ["\027Oc"] = "Ctrl-Right",
  ["\027Od"] = "Ctrl-Left",
  ["\027OH"] = "Cmd-Left",
  ["\027OF"] = "Cmd-Right",
  -- the "\027[" prefix is detected in code
  ["\027[1;2A"] = "Shift-Up",
  ["\027[1;2B"] = "Shift-Down",
  ["\027[1;2C"] = "Shift-Right",
  ["\027[1;2D"] = "Shift-Left",
  ["\027[1;5A"] = "Ctrl-Up",
  ["\027[1;5B"] = "Ctrl-Down",
  ["\027[1;5C"] = "Ctrl-Right",
  ["\027[1;5D"] = "Ctrl-Left",
  ["\027[1;6A"] = "Ctrl-Shift-Up",
  ["\027[1;6B"] = "Ctrl-Shift-Down",
  ["\027[1;6C"] = "Ctrl-Shift-Right",
  ["\027[1;6D"] = "Ctrl-Shift-Left",
  ["\027[1;9A"] = "Alt-Up",
  ["\027[1;9B"] = "Alt-Down",
  ["\027[1;9C"] = "Alt-Right",
  ["\027[1;9D"] = "Alt-Left",
  ["\027[1;10A"] = "Alt-Shift-Up",
  ["\027[1;10B"] = "Alt-Shift-Down",
  ["\027[1;10C"] = "Alt-Shift-Right",
  ["\027[1;10D"] = "Alt-Shift-Left",
  ["\027[3~"] = "Delete",
  ["\027[5~"] = "fn-Up",
  ["\027[6~"] = "fn-Down",
  ["\027[a"] = "Shift-Up",
  ["\027[A"] = "Up",
  ["\027[B"] = "Down",
  ["\027[b"] = "Shift-Down",
  ["\027[C"] = "Right",
  ["\027[c"] = "Shift-Right",
  ["\027[D"] = "Left",
  ["\027[d"] = "Shift-Left",
  ["\027[F"] = "fn-Right",
  ["\027[H"] = "fn-Left",
  ["\027[Z"] = "Shift-Tab",
  ["\127"] = "Backspace",
}

ANSIParser.new = O.constructor(function (self, input)
  self.input = input
  self.buf = buffer.new()

  self.keys = T.Mailbox:new()
  self.cursor_positions = T.Mailbox:new()
  T.go(self._loop, self)
end)

function ANSIParser:feed()
  local input, err = loop.read(io.stdin)
  if input then
    self.buf:write(input)
  else
    error(err)
  end
end

function ANSIParser:_loop()
  io.immediate_stdin(true)

  local n = 1
  while true do
    if #self.buf < n then self:feed() end
    local c = self.buf:peek(n)
    local key = self.keyseqs[c]
    if type(key) == 'number' then
      -- `key` more bytes needed
      n = n + key
    elseif key then
      self.keys:put('key', key)
      self.buf:rseek(n) n = 1
    elseif c == '\027[' then
      local function parse(text)
        local row, col, cprlen = string.match(text, "^\027%[([0-9]*);([0-9]*)()R")
        if row and col then
          self.cursor_positions:put(tonumber(row) or 1, tonumber(col) or 1)
          self.buf:rseek(cprlen)
          return true
        end
        local esc, esclen = string.match(text, "^(\027%[[0-9;]*()[a-zA-Z~])")
        if esc then
          key = self.keyseqs[esc]
          if key then
            self.keys:put('key', key)
          else
            self.keys:put('unknown-seq', esc)
          end
          self.buf:rseek(esclen)
          return true
        end
      end
      while not parse(self.buf:peek()) do self:feed() end
      n = 1
    else
      self.keys:put('text', self.buf:readuntil('\027') or self.buf:read())
      n = 1
    end
  end
end

local ANSIBuffer = O()

ANSIBuffer.new = O.constructor(function (self, buf)
  self.buffer = buf or buffer:new()
end)

function ANSIBuffer:write(...)
  self.buffer:write(...)
  return self
end

function ANSIBuffer:beep()
  return self:write'\7'
end

function ANSIBuffer:clearline()
  return self:write'\r\027[0K'
end

function ANSIBuffer:up(rows)
  rows = rows or 1
  if rows == 0 then
    return self
  elseif rows > 0 then
    return self:write('\027['..rows..'A')
  else
    return self:write('\027['..-rows..'B')
  end
end

function ANSIBuffer:down(rows)
  rows = rows or 1
  return self:up(-rows)
end

function ANSIBuffer:left(cols)
  cols = cols or 1
  if cols == 0 then
    return self
  else
    return self:write('\027['..cols..'D')
  end
end

function ANSIBuffer:right(cols)
  cols = cols or 1
  if cols == 0 then
    return self
  else
    return self:write('\027['..cols..'C')
  end
end

function ANSIBuffer:col(col)
  col = col or 1
  if col == 1 then
    return self:write'\r'
  else
    return self:write('\r\027['..(col-1)..'C')
  end
end

function ANSIBuffer:flush(out)
  out:write(self.buffer:read())
  out:flush()
  return self
end



local UnicodeText = O()
UnicodeText.__type = 'lineedit.UnicodeText'

UnicodeText.new = O.constructor(function (self, bytes, start_vcol)
  local vcol, off = start_vcol or  1, 1
  local vcols, offsets, revoff = { vcol }, { off }, { 1 }
  local screenwidths, bytewidths = unicode.codepoint_widths(bytes)
  local j=1
  for i=1,#screenwidths do
    local width = string.byte(screenwidths, i)
    vcol = vcol + width
    off = off + string.byte(bytewidths, i)
    if width > 0 then
      j = j + 1
    end
    vcols[j] = vcol
    offsets[j] = off
    revoff[off] = j
  end
  self.bytes = bytes
  self.vcols = vcols
  self.offsets = offsets
  self.revoffsets = revoff
end)

function UnicodeText:length()
  return #self.vcols-1
end

function UnicodeText:size()
  return self.vcols[#self.vcols]
end

function UnicodeText:wrapped_position(pos, cols)
  if pos == -1 then pos = #self.vcols end
  if pos > #self.vcols then pos = #self.vcols end
  local vcol = self.vcols[pos]
  local crow = math.ceil((vcol-1) / cols)
  local ccol = (vcol-1) % cols + 1
  if ccol == 1 and pos == #self.vcols then ccol = cols end
  return crow, ccol
end

function UnicodeText:wrapped_size(cols)
  return math.ceil((self.vcols[#self.vcols]-1) / cols), cols
end

function UnicodeText:match(pattern, start)
  if start > #self.vcols then start = #self.vcols end
  local results = {self.bytes:match(pattern, self.offsets[start])}
  for i,r in ipairs(results) do
    if type(r) == 'number' then
      results[i] = self.revoffsets[r]
    end
  end
  return unpack(results)
end

function UnicodeText:sub(s, e)
  if not s then s = 1 end
  if s > #self.vcols then s = #self.vcols end
  if not e or e == -1 or e > #self.vcols then e = #self.vcols else e = e + 1 end
  if e < s then return '' end
  D'sub:'(s, e, self.offsets[s], self.offsets[e])
  return string.sub(self.bytes, self.offsets[s], self.offsets[e] - 1)
end

local function test_UnicodeText()
  local ut = UnicodeText:new('❓ąą🙂')
  assert(ut.vcols[1] == 1)
  assert(ut.vcols[2] == 3)
  assert(ut.vcols[3] == 4)
  assert(ut.vcols[4] == 5)
  assert(ut.vcols[5] == 7)
  assert(D'1'(ut:sub(3)) == 'ą🙂')
  assert(D'1'(ut:sub(4)) == '🙂')
  assert(D'2'(ut:sub(1,1)) == '❓')
  assert(D'3'(ut:sub(2,3)) == 'ąą')
  assert(D'4'(ut:sub(3,3)) == 'ą')
  assert(D'5'(ut:sub(4,4)) == '🙂')
end



local Prompt = O()
Prompt.__type = 'lineedit.Prompt'

Prompt.word_separators = '():,.;~*+%-=[%]{} '
Prompt.after_word = '[^'..Prompt.word_separators..']+()'
Prompt.start_of_word = '['..Prompt.word_separators..']+()'

Prompt.new = O.constructor(function (self, input, output, opts)
  opts = opts or {}
  self.input = input
  self.output = output
  self.buf = ANSIBuffer:new()
  self.lines = T.Mailbox:new()

  self.history = opts.history or {}
  self.history_offset = 1

  self.prompt = UnicodeText:new(opts.prompt or '❓ ')
  self.text = self:setText('')
  self.pos = 1

  self.onscreen_prompt = UnicodeText:new('')
  self.onscreen_text = UnicodeText:new('', self.onscreen_prompt:size())
  self.onscreen_pos = 1

  self.onscreen_columns = 0
end)

function Prompt:setPrompt(bytes)
  self.prompt = UnicodeText:new(bytes)
  self:setText(self.text.bytes)
end

function Prompt:setText(bytes)
  self.text = UnicodeText:new(bytes, self.prompt:size())
end

function Prompt:buf_clear_onsceen()
  local rows = self.onscreen_text:wrapped_size(self.onscreen_columns)
  local crow = self.onscreen_text:wrapped_position(self.onscreen_pos, self.onscreen_columns)
  self.buf:down(rows - crow)
  for _=1,rows-1 do
    self.buf:clearline():up()
  end
  self.buf:clearline()
  return self.buf
end

function Prompt:buf_position_cursor()
  local crow = self.onscreen_text:wrapped_position(self.onscreen_pos, self.onscreen_columns)
  local row, col = self.onscreen_text:wrapped_position(self.pos, self.onscreen_columns)
  self.buf:up(crow - row):col(col)
  self.onscreen_pos = self.pos
  return self.buf
end

function Prompt:draw()
  local _, cols = io.get_term_size()
  self.onscreen_columns = cols

  self:buf_clear_onsceen()
  self.buf:write(self.prompt.bytes):write(self.text.bytes)
  self.onscreen_prompt = self.prompt
  self.onscreen_text = self.text
  self.onscreen_pos = -1
  self:buf_position_cursor()
  self.buf:flush(self.output)
end

function Prompt:update()
  local _, term_columns = io.get_term_size()
  if term_columns ~= self.onscreen_columns or
     self.text ~= self.onscreen_text or
     self.prompt ~= self.onscreen_prompt then
    self:draw(self.prompt, self.text, self.pos)
  else
    self:buf_position_cursor():flush(self.output)
  end
end

function Prompt:move(cols)
  if type(cols) == 'number' then
    self.pos = self.pos + cols
  end
  if cols == 'start' or self.pos < 1 then self.pos = 1 end
  local max = self.text:length()+1
  if cols == 'end' or self.pos > max then self.pos = max end
  self.keepend = self.pos >= max
  return self
end

function Prompt:findRelPosAfterWord()
  local n = self.onscreen_text:match(self.after_word, self.pos)
  if n then
    return n - self.pos
  else
    return self.text:length()+1 - self.pos
  end
end

function Prompt:findRelPosStartOfWord()
  local best = 1
  local n = 1
  while n and n < self.pos do
    best = n
    n = self.text:match(self.start_of_word, n)
  end
  return best - self.pos
end

function Prompt:insertText(text)
  self:setText(self.text:sub(1, self.pos-1) .. text .. self.text:sub(self.pos))
  return self
end

function Prompt:delete(ostart, oend)
  oend = oend or ostart
  self:setText(self.text:sub(1, ostart - 1)..self.text:sub(oend + 1))
  return self
end

function Prompt:addToHistory(text)
  if self.history[#self.history] ~= text then
    self.history[#self.history + 1] = text
  end
  self.history_offset = 1
  return self
end

function Prompt:setTextFromHistory()
  self:setText(self.history[#self.history + self.history_offset] or self.new_history_item)
end

function Prompt:historyPrev()
  if self.history_offset == 1 then self.new_history_item = self.text end
  local abs = #self.history + self.history_offset
  if abs <= 1 then return self.buf:beep() end
  local prefix = self.text:sub(1, self.pos)
  while abs > 1 do
    abs = abs - 1
    if #prefix == 0 or self.history[abs]:startswith(prefix) then
      self.history_offset = abs - #self.history
      self:setTextFromHistory()
      return
    end
  end
end

function Prompt:historyNext()
  if self.history_offset == 1 then return self.buf:beep() end
  local abs = #self.history + self.history_offset
  local prefix = self.text:sub(1, self.pos)
  while abs <= #self.history do
    abs = abs + 1
    if #prefix == 0 or (self.history[abs] or self.new_history_item):startswith(prefix) then
      self.history_offset = abs - #self.history
      self:setTextFromHistory()
      return
    end
  end
end

function Prompt:handleInput(kind, data)
  D'»'(kind, data)
  if kind == 'key' then
    if data == 'Left' then
      self:move(-1)
    elseif data == 'Right' then
      self:move(1)
    elseif data == 'Cmd-Left' or data == 'fn-Left' then
      self:move'start'
    elseif data == 'Cmd-Right' or data == 'fn-Right' then
      self:move'end'
    elseif data == 'Ctrl-Right' then
      self:move(D'ff:'(self:findRelPosAfterWord()))
    elseif data == 'Ctrl-Left' then
      self:move(D'fb:'(self:findRelPosStartOfWord()))
    elseif data == 'Up' then
      self:historyPrev()
    elseif data == 'Down' then
      self:historyNext()
    elseif data == 'Backspace' then
      self:move(-1)
      self:delete(self.pos)
    elseif data == 'Delete' then
      self:delete(self.pos)
    elseif data == 'Ctrl-W' then
      local n = self:findRelPosStartOfWord()
      self:move(n)
      self:delete(self.pos, self.pos-n-1)
    elseif data == 'Enter' then
      self.lines:put(self.text)
      self:addToHistory(self.text)
      self:setText('')
    elseif data == 'EOF' then
      self.lines:put(data)
    end
  elseif kind == 'text' then
    self:insertText(data)
    self:move(UnicodeText:new(data):length())
  end
  return self
end

local input = ANSIParser:new(io.stdin)
local prompt = Prompt:new(input, io.stdout, { history = {'ą', 'b', 'cde', 'ąbc', 'ąaa'} })

T.go(function ()
  -- prompt:setText("❓aą aą🙂-"..string.rep('aaaabbbbcccc ', 30)..'🙂')
  -- prompt:setText("❓aą aą")
  prompt:setText("ą")
  prompt:update()
  while true do
    local kind, data = input.keys:recv()
    prompt:handleInput(kind, data):update()
  end
end)

loop.run()
