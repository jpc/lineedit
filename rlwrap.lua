local T = require'thread'
local loop = require'loop'
local lineedit = require'lineedit'
local D = require'util'
D.prepend_thread_names = false
D.prepend_timestamps = false
local subproc = require'subproc'



local prompt = lineedit.Prompt:new(io.stdin, io.stdout, { history = {
  "io.stderr:write('qwe')",
  "io.stdout:write('qwe')",
  "io.stderr:write('qwe\\n')",
  "io.stdout:write('qwe\\n')",
}})

local sub = subproc:new(unpack(arg)):pty():start()

local output_lines = T.Mailbox:new()

T.go(function ()
  prompt:update()
  local output_timer
  while true do
    T.recv{
      [prompt.input.keys] = function (kind, data)
        local line, eof = prompt:handleInput(kind, data)
        if line then
          loop.write(sub._stdin.w, line..'\n')
        elseif eof then
          return loop.write(sub._stdin.w, '\004')
        end
        prompt:update()
      end,
      [output_timer or output_lines] = function (...)
        if output_timer then
          output_timer = nil
          prompt:write(function (buf)
            while true do
              local ok, msg = output_lines:poll()
              if not ok then break end
              buf:write(msg[1])
            end
          end)
        else
          output_lines:putback(...)
          output_timer = T.Timeout:new(0.05)
        end
      end
    }
  end
end)

T.go(function ()
  while true do
    local line, err = loop.read(sub._stdout.r)
    if line then
      output_lines:put(line)
    else
      if err == 'eof' then
        os.exit(sub:wait().exit_status)
      end
      D'read error:'(err)
      os.exit(254)
    end
  end
end)

loop.run()
