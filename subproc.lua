local T = require'thread'
local O = require'o'
local o = require'kvo'
local D = require'util'
local ev = require'ev'
local loop = require'loop'
local posix = require'posix'
local bio = require'bio'
local json = require'cjson'


local subproc = O()
subproc.__type = 'subproc'

subproc.new = O.constructor(function (self, cmd, ...)
    self._cmd = cmd
    self._args = {...}
    self._status = o(nil)
    self._status:recv() -- initialize async support
end)

local function pipe(noinherit)
    local r, w = assert(posix.pipe())
    if noinherit == 'r' then io.setinherit(r, false) end
    if noinherit == 'w' then io.setinherit(w, false) end
    return { r = r, w = w }
end

function subproc:stdin(fd)
    if fd == 'pipe' then
        self._stdin = pipe('w')
    elseif type(fd) == 'table' and fd.r then
        self._stdin = fd
    elseif io.getfd(fd) then
        self._stdin = { r = fd }
    else
        return error('invalid file descriptor specifier: '..D.repr(fd))
    end
    return self
end

function subproc:stdout(fd)
    if fd == 'pipe' then
        self._stdout = pipe('r')
    elseif type(fd) == 'table' and fd.w then
        self._stdout = fd
    elseif io.getfd(fd) then
        self._stdout = { w = fd }
    else
        return error('invalid file descriptor specifier: '..D.repr(fd))
    end
    return self
end

function subproc:stderr(fd)
    if fd == 'pipe' then
        self._stderr = pipe('r')
    elseif type(fd) == 'table' and fd.w then
        self._stderr = fd
    elseif io.getfd(fd) then
        self._stderr = { w = fd }
    else
        return error('invalid file descriptor specifier: '..D.repr(fd))
    end
    return self
end

function subproc:pty()
    self._pty  = true
    return self
end

function subproc:start()
    local pid, pty
    if self._pty then
        pid, pty = assert(os.forkpty())
    else
        pid = assert(posix.fork())
    end
    if pid == 0 then -- child
        if self._stdin then assert(posix.dup2(self._stdin.r, 0)) end
        if self._stdout then assert(posix.dup2(self._stdout.w, 1)) end
        if self._stderr then assert(posix.dup2(self._stderr.w, 2)) end
        for i=3,30 do posix.close(i) end -- most descriptors in Lua are inheritable, clean it up with brute force

        return assert(posix.exec(self._cmd, unpack(self._args)))
    end

    ev.Child.new(function (_, child, _) self._status(child:getstatus()) end, pid, false):start(loop.default)

    self._pid = pid
    if self._pty then
        self._termios = io.tty_noecho(pty) -- disables echo and lf->crlf conversion
        self._stdin = { w = pty }
        self._stdout = { r = pty }
        self._stderr = { r = pty }
    else
        if self._stdin then posix.close(self._stdin.r) end
        if self._stdout then posix.close(self._stdout.w) end
        if self._stderr then posix.close(self._stderr.w) end
    end

    return self
end

function subproc:wait()
    assert(self._pid, "subproc must be started before calling wait")
    return self._status() or self._status:recv()
end

function subproc:communicate(input)
    if not self._stdin then self:stdin'pipe' end
    if not self._stdout then self:stdout'pipe' end
    assert(self._stdin.w, 'stdin has no write endpoint')
    assert(self._stdout.r, 'stdout has no read endpoint')
    self:start()
    local chn = T.Mailbox:new()
    local thd = T.go(function ()
        local out = {}
        while true do
            local data, err = loop.read(self._stdout.r)
            if data then
                out[#out+1] = data
            else
                out = table.concat(out)
                if err == 'eof' then err = nil end
                io.raw_close(self._stdout.r)
                chn:put(out, err)
                return
            end
        end
    end)
    loop.write(self._stdin.w, input)
    io.raw_close(self._stdin.w)
    local data, err = chn:recv()
    if err then error(err) end
    return data, status
end

-- function subproc:close()
--   io.raw_close(self._stdin.w)
--   io.raw_close(self._stdout.r)
--   io.raw_close(self._stderr.r)
-- end

function subproc.popen_lines(cmd)
    local fd, err = io.popen(cmd, "r")
    if not fd then log:struct('popen-error', { error = err, cmd = cmd, when = 'popen' }) return end
    local b = bio.IBuf:new(fd)
    return function ()
        local line, err = b:readuntil('\n')
        if err == 'eof' then return nil, fd:close() end
        if not line then log:struct('popen-error', { error = err, cmd = cmd, when = 'read-line' }) return end
        return line
    end
end

function try_monitor_jlog(fname, cb)
    local lines = subproc.popen_lines("exec tail +0 -F "..fname)
    while true do
        line = lines()
        if not line then break end
        local data = string.match(line, "^[%%0-9a-f._: -]*~ [0-9.]+ (%[.+%])$")
        if not data then
            data = string.match(line, "^[%%0-9a-f._:-]* (%[.+%])$")
        end
        -- D'»'(fname, line, data)
        if data then
            local ok, r = T.spcall(json.decode, data)
            if not ok then
                D.red'json parse error'(r, data)
            else
                cb(r)
            end
        end
    end
end

function subproc.monitor_jlog(fname, cb)
    T.go(function ()
        while true do try_monitor_jlog(fname, cb) end
    end)
end

local function last_modification(fname)
    local stat = lfs.attributes(fname)
    if not stat then return nil end
    return stat.modification
end

function subproc.monitor_file(fname, cb)
    T.go(function ()
        local last_tmod = nil
        while true do
            local tmod = last_modification(fname)
            if not tmod then
                cb(nil)
            elseif tmod ~= last_tmod then
                local fd, err = io.open(fname)
                if not fd then cb(nil, err) end
                cb(fd:read'*a', tmod)
                last_tmod = tmod
            end
            T.sleep(1)
        end
    end)
end

function subproc.monitor_service(dir, cb)
    subproc.monitor_file(dir..'/supervise/status', function ()
        local fd, err = io.open(dir..'/supervise/stat')
        if not fd then return cb(nil, err) end
        cb(fd:read'*a':strip())
    end)
end

function subproc.get_mem_usage()
    local meminfo = assert(io.open("/proc/meminfo", 'r')):read'*a'
    return tonumber(string.match(meminfo, 'MemTotal: +([0-9]+) kB')), tonumber(string.match(meminfo, 'MemAvailable: +([0-9]+) kB'))
end

return subproc
