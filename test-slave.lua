local T = require'thread'
require'loop'
function test()
  T.sleep(1)
  io.stderr:write('qwe\n')
  T.sleep(1)
  io.stdout:write('qwe\n')
  T.sleep(5)
  io.stderr:write('[') for i=1,20 do io.stderr:write('.') T.sleep(.5) end io.stderr:write(']\n')
end
-- test()
if io.isatty(0) then require'repl'.start(0) end
require'loop'.run()
