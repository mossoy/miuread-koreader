local Json = require("miuread.json")
local U = require("miuread.util")
local Adapter = require("miuread.legacy_adapter_worker")

local Daemon = {}

local function sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
        return
    end
    os.execute("sleep " .. tostring(math.max(1, math.floor(seconds or 1))))
end

local function lower_priority()
    pcall(function()
        local ffi = require("ffi")
        ffi.cdef[[
            int getpid(void);
            int setpriority(int which, int who, int prio);
        ]]
        ffi.C.setpriority(0, ffi.C.getpid(), 10)
    end)
end

local function read_json(path)
    local raw = U.read_file(path, true)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    if ok and type(value) == "table" then return value end
end

local function write_status(path, value)
    value = value or {}
    value.written_at = os.time()
    return U.atomic_write(path, Json.encode(value), true)
end

local function public_result(result)
    result = type(result) == "table" and result or {}
    return {
        accepted = result.accepted == true,
        response = result.response or {},
        error = result.error,
        error_kind = result.error_kind,
        path = result.path,
        context_changed = result.context_changed == true,
        position = result.position,
        cookies_changed = result.cookies_changed == true,
        cookies = result.cookies_changed and result.cookies or nil,
        wr_ticket_changed = result.wr_ticket_changed == true,
        wr_ticket = result.wr_ticket_changed and result.wr_ticket or nil,
        wr_wrpa_changed = result.wr_wrpa_changed == true,
        wr_wrpa = result.wr_wrpa_changed and result.wr_wrpa or nil,
        response_summary = result.response_summary,
        attempts = result.attempts,
        payload_public = result.payload_public,
    }
end

function Daemon.run(job)
    job = job or {}
    local control_path = assert(job.control_path, "missing control path")
    local status_path = assert(job.status_path, "missing status path")
    local stop_path = assert(job.stop_path, "missing stop path")
    local context_path = assert(job.context_path, "missing context path")
    local interval = math.max(10, tonumber(job.interval) or 30)
    local idle_timeout = math.max(interval, tonumber(job.idle_timeout) or 600)
    local poll_interval = math.max(0.5, tonumber(job.poll_interval) or 1)
    local book = U.copy(job.book or {})
    local auth = U.copy(job.auth or {})
    local book_id = tostring(job.book_id or "")
    local book_title = tostring(job.book_title or book_id)
    local sequence = 0
    local next_due = os.time() + interval

    lower_priority()
    U.atomic_write(context_path, Json.encode(book), true)
    write_status(status_path, {
        seq = sequence,
        state = "waiting",
        next_due = next_due,
        started_at = os.time(),
        book_id = book_id,
    })

    while true do
        if U.file_exists(stop_path) then break end
        local control = read_json(control_path)
        if control and control.active == false then break end

        local now = os.time()
        if now >= next_due then
            local last_activity = tonumber(control and control.last_activity) or now
            local idle = now - last_activity
            if idle <= idle_timeout and control and control.active ~= false then
                sequence = sequence + 1
                write_status(status_path, {
                    seq = sequence,
                    state = "uploading",
                    attempted_at = now,
                    next_due = now + interval,
                    book_id = book_id,
                })

                local report_job = {
                    book_id = book_id,
                    book_title = book_title,
                    book = book,
                    progress_ratio = tonumber(control.progress_ratio) or 0,
                    elapsed_seconds = interval,
                    cookies = auth.cookies or {},
                    api_key = auth.api_key or "",
                    wr_ticket = auth.wr_ticket or "",
                    wr_wrpa = auth.wr_wrpa or "",
                    allow_renewal = false,
                }
                local ok, result = pcall(Adapter.run, report_job)
                if ok and type(result) == "table" then
                    if type(result.legacy_context) == "table" then
                        book = U.copy(result.legacy_context)
                        if result.context_changed then U.atomic_write(context_path, Json.encode(book), true) end
                    end
                    if result.cookies_changed and type(result.cookies) == "table" then auth.cookies = U.copy(result.cookies) end
                    if result.wr_ticket_changed then auth.wr_ticket = result.wr_ticket or "" end
                    if result.wr_wrpa_changed then auth.wr_wrpa = result.wr_wrpa or "" end
                    local out = public_result(result)
                    out.seq = sequence
                    out.state = result.accepted and "waiting" or "error"
                    out.attempted_at = now
                    out.completed_at = os.time()
                    out.next_due = out.completed_at + interval
                    out.book_id = book_id
                    write_status(status_path, out)
                    next_due = out.next_due
                else
                    local completed = os.time()
                    write_status(status_path, {
                        seq = sequence,
                        state = "error",
                        accepted = false,
                        error = tostring(result or "read report daemon failed"),
                        attempted_at = now,
                        completed_at = completed,
                        next_due = completed + interval,
                        book_id = book_id,
                    })
                    next_due = completed + interval
                end
            else
                next_due = now + interval
                write_status(status_path, {
                    seq = sequence,
                    state = "idle",
                    next_due = next_due,
                    book_id = book_id,
                })
            end
        end
        sleep(poll_interval)
    end

    U.atomic_write(context_path, Json.encode(book), true)
    write_status(status_path, {
        seq = sequence,
        state = "stopped",
        stopped_at = os.time(),
        book_id = book_id,
        context_changed = true,
    })
    return true
end

return Daemon
