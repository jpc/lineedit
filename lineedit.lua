local T = require'thread'
local loop = require'loop'
local D = require'util'
D.prepend_thread_names = false
D.prepend_timestamps = false
local buffer = require'buffer'
local O = require'o'



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
        local row, col, cprlen = string.match(text, "\027%[([0-9]*);([0-9]*)()R")
        if row and col then
          D'rc'(row, col)
          self.cursor_positions:put(tonumber(row) or 1, tonumber(col) or 1)
          self.buf:rseek(cprlen)
          return true
        end
        local esc, esclen = string.match(text, "(\027%[[0-9;]*()[a-zA-Z~])")
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

function ANSIBuffer:moveto(row, col)
  return self:write('\027['..row..';'..col..'H')
end

function ANSIBuffer:moverel(drow, dcol)
  if drow < 0 then self:up(-drow)
  elseif drow > 0 then self:down(drow) end
  if dcol < 0 then self:left(-dcol)
  elseif dcol > 0 then self:right(dcol) end
  return self
end

function ANSIBuffer:up(rows)
  rows = rows or 1
  if rows == 0 then
    return self
  else
    return self:write('\027['..rows..'A')
  end
end

function ANSIBuffer:down(rows)
  rows = rows or 1
  if rows == 0 then
    return self
  else
    return self:write('\027['..rows..'B')
  end
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
  col = col or 0
  if col == 0 then
    return self:write'\r'
  else
    return self:write('\r\027['..col..'C')
  end
end

function ANSIBuffer:flush(out)
  out:write(self.buffer:read())
  out:flush()
  return self
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
  self.history = opts.history or {}
  self.prompt = opts.prompt or '❓ ' self.text = '' self.pos = 1
  self.onscreen_prompt = '' self.onscreen_text = '' self.onscreen_pos = 1
  self.onscreen_columns = 0
  self.history_offset = 1
  self._grapheme_widths = {}
  self.valid_offsets = { 1 }
  self.valid_positions = { {0,0} }
  self.buf = ANSIBuffer:new()
  self.lines = T.Mailbox:new()
end)

local function unwrap(pos, cols)
  return pos[1] * cols + pos[2]
end

local function wrap(vcol, cols)
  local crow = math.floor(vcol / cols)
  local ccol = vcol % cols
  return crow, ccol
end

function Prompt:_calc_position(prompt, text, pos)
  -- D'_calc_position'(pos, self.valid_positions)
  local _, cols = io.get_term_size()
  local crow, ccol = wrap(unwrap(self.valid_positions[pos], self.onscreen_columns), cols)
  local rows = math.ceil(unwrap(self.valid_positions[#self.valid_positions], self.onscreen_columns) / cols)
  -- local rows = math.ceil((#prompt + #text) / cols)
  -- local crow = math.floor(pos / cols)
  -- local ccol = pos % cols
  return crow, ccol, rows
end

function Prompt:clear_onscreen()
  -- self.buf:write'\027[6n':flush(self.output)
  -- local row, col = self.input.cursor_positions:recv()
  -- local cyx = self.valid_positions[self.onscreen_pos]
  -- local last_yx = self.valid_positions[#self.valid_positions]
  local crow, _, rows = D'_calc_position:'(self:_calc_position(self.onscreen_prompt, self.onscreen_text, self.onscreen_pos))
  self.buf:down(rows-1 - crow)
  for _=1,rows-1 do
    self.buf:clearline():up()
  end
  self.buf:clearline()
end

function Prompt:position_cursor()
  -- self.buf:up(rows-1 - crow):col(ccol):flush(self.output)
  local cyx = assert(self.valid_positions[self.onscreen_pos])
  local yx = assert(self.valid_positions[self.pos])
  self.buf:moverel(yx[1]-cyx[1], yx[2]-cyx[2]):flush(self.output)
  self.onscreen_pos = self.pos
end

function Prompt:draw()
  D'@'(self.text)
  D'@'(D.unq(self.text))
  local _, term_columns = io.get_term_size()
  local dx = self._grapheme_widths
  local offsets = self.valid_offsets
  local valid_positions = self.valid_positions
  local n = 1
  local query_text = string.gsub(self.text, "(()[%z\1-\127\194-\244][\128-\191]*)", function (char, offset)
    offsets[n] = offset
    if string.byte(char) > 127 then
      dx[n] = "?"
      n = n + 1
      return char..'\027[6n'
    else
      dx[n] = 1
      n = n + 1
      return char..'\027[6n'
      -- return char
    end
  end)
  for i=n,#offsets do dx[i] = nil offsets[i] = nil valid_positions[i] = nil end
  offsets[n] = #self.text
  -- self.buf:write('\027[6n\0277'..self.prompt..self.text..'\027[6n\0278\027[6n')
  self.buf:write'\027[6n':write(self.prompt):write'\027[6n':write(query_text):write'\027[6n':flush(self.output)
  -- D'poss'({self.input.cursor_positions:recv()},{self.input.cursor_positions:recv()},{self.input.cursor_positions:recv()})
  local start_row, start_col = self.input.cursor_positions:recv()
  local row, col = self.input.cursor_positions:recv()
  local prev_row, prev_col
  local j = 1
  D'dx'(dx)
  for i=1,n do
    -- D'row, col:'(row, col, dx[i], term_columns, string.sub(self.text, offsets[i] or -1))
    if col ~= prev_col or row ~= prev_row then
      valid_positions[j] = { row--[[ - start_row]], col--[[ - start_col]] }
      prev_row = row--[[ - start_row]] prev_col = col--[[ - start_col]]
      j = j + 1
    else
      table.remove(offsets, i-1)
    end
    if dx[i] == '?' then
      row, col = self.input.cursor_positions:recv()
    elseif dx[i] then
      row, col = self.input.cursor_positions:recv()
      -- col = col + dx[i]
      while col > term_columns do
        row = row + 1
        col = col - term_columns
      end
    end
  end
  D'dx'(dx)
  D'@'(self.valid_positions)
  self.onscreen_pos = #self.valid_positions
  self:position_cursor()
  self.onscreen_prompt = self.prompt
  self.onscreen_text = self.text
  self.onscreen_columns = term_columns
end

function Prompt:update()
  local _, term_columns = io.get_term_size()
  if term_columns ~= self.onscreen_columns or
     self.text ~= self.onscreen_text or
     self.prompt ~= self.onscreen_prompt then
    D'redraw'()
    self:clear_onscreen()
    self:draw(self.prompt, self.text, self.pos)
  else
    D'reposition'()
    self:position_cursor()
  end
end

function Prompt:setText(text, keepend)
  if keepend ~= false then
    D'keepend'(self.pos, self.valid_positions)
    if self.pos >= #self.valid_positions then self.pos = #self.valid_positions end
  end
  if self.pos >= #text then self.pos = #text end
  self.text = text
  return self
end

function Prompt:move(cols)
  if type(cols) == 'number' then
    self.pos = self.pos + cols
  end
  if cols == 'start' or self.pos < 1 then self.pos = 1 end
  if cols == 'end' or self.pos > #self.valid_positions then self.pos = #self.valid_positions end
  return self
end

function Prompt:findRelPosAfterWord()
  local n = self.text:match(self.after_word, self.pos+1 + 1)
  if n then
    return n-1 - self.pos
  else
    return #self.text - self.pos
  end
end

function Prompt:findRelPosStartOfWord()
  local best = 1
  local n = 1
  while n and n-1 < self.pos do
    best = n
    n = self.text:match(self.start_of_word, n)
  end
  return best-1 - self.pos
end

function Prompt:insertText(text)
  self:setText(self.text:sub(1, self.pos) .. text .. self.text:sub(self.pos+1))
  return self
end

function Prompt:delete(ostart, oend)
  oend = oend or ostart
  self:setText(self.text:sub(1, ostart+1 - 1)..self.text:sub(oend+1 + 1))
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
  self:setText(self.history[#self.history + self.history_offset] or self.new_history_item, false)
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
    self:move(#data)
  end
  D'='(self.history_offset, self.pos, self.valid_positions[self.pos])
  return self
end

local input = ANSIParser:new(io.stdin)
local prompt = Prompt:new(input, io.stdout, {'a', 'b', 'cde'})

local function utf8len(text)
  local _, count = string.gsub(text, "[^\128-\193]", "")
  return count
end

function utf8iter(text)
  for uchar in string.gmatch(text, "([%z\1-\127\194-\244][\128-\191]*)") do
    D'#'(uchar)
    -- something
  end
end

function test(text)
  D'@'(text)
  D'@'(D.unq(text))
  local offsets = {}
  local dx = {}
  local ntext = string.gsub(text, "(()[%z\1-\127\194-\244][\128-\191]*)", function (char, i)
    offsets[#offsets+1] = i
    if string.byte(char) > 127 then
      dx[#dx+1] = "?"
      return char..'\027[6n'
    else
      dx[#dx+1] = 1
      return char
    end
  end)
  offsets[#offsets+1] = #text
  io.stdout:write('\027[6n', ntext) io.stdout:flush()
  local valid_positions = {}
  local col = input.cursor_positions:recv()
  for i=1,#dx+1 do
    if col ~= valid_positions[#valid_positions] then
      valid_positions[#valid_positions+1] = col
    else
      table.remove(offsets, i-1)
    end
    if dx[i] == '?' then
      local ncol = input.cursor_positions:recv()
    elseif dx[i] then
      col = col + dx[i]
    end
  end
  D'@'(offsets)
  D'C'(valid_positions)
end

-- utf8iter("abcąść abcąść")
--test("abcąść abcąść") -- breaks thread.lua

T.go(function ()
  -- test("❓abcąść abcąść-")
  -- test("❓aą aą🙂-")
  -- test("aą-❓")
  -- prompt:setText(string.rep('aaaabbbbcccc ', 30)):move(-150):update()
  prompt:setText("❓aą aą🙂-"..string.rep('aaaabbbbcccc ', 3)..'🙂'):update()
  while true do
    local kind, data = D'key:'(input.keys:recv())
    prompt:handleInput(kind, data):update()
    -- p:setText(D.repr(kind, data)..string.rep('-', 300)):draw()
    -- D.cyan('» ', io.stdout)()
    -- io.stdout:write(string.rep('-', 300)) io.stdout:flush()
    -- io.stdout:write('\027[2F') io.stdout:flush()
    -- io.stdout:write('\027[u') io.stdout:flush()
  end
end)

-- T.go(function ()
--   T.sleep(1)
--   io.stdout:write('\027[6n')
--   D'!'()
-- end)

-- while true do
  -- io.stdout:write('» ')
  -- io.stdout:flush()

  -- local text = buf:readuntil('\027', 1)
  -- if text then
  --   if text ~= '' then
  --     D'«'(buf:read())
  --   end
  --   D'#'(buf:read())
  -- else
  --   D'«'(buf:read())
  -- end
  -- for _,i in ipairs(string.split[[
  --   ↑ ↓ ← →
  --   ⇧↑ ⇧↓ ⇧← ⇧→
  --   ⌃↑ ⌃↓ ⌃← ⌃→
  --   ⌥↑ ⌥↓ ⌥← ⌥→
  --   ⌘↑ ⌘↓ ⌘← ⌘→
  --   ⌘⏎ ⇧⏎ ⌃⏎ ⌥⏎]]) do
  --   io.stdout:write(i..' ') io.stdout:flush()
    -- D'«'(io.raw_read(io.stdin))
  -- end
-- end

loop.run()
