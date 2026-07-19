local Json = require("miuread.json")
local U = require("miuread.util")
local Adapter = require("miuread.legacy_adapter_worker")

local Service = {}

local function sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
        return
    end
    os.execute("sleep " .. tostring(math.max(1, math.floor(seconds or 1))))
end

local function process_helpers()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    pcall(function()
        ffi.cdef[[
            int getpid(void);
            int setpriority(int which, int who, int prio);
            int kill(int pid, int sig);
        ]]
    end)
    return ffi
end

local ffi = process_helpers()

local function lower_priority()
    if not ffi then return end
    pcall(function() ffi.C.setpriority(0, ffi.C.getpid(), 19) end)
end

local function own_pid()
    if not ffi then return nil end
    local ok, pid = pcall(function() return tonumber(ffi.C.getpid()) end)
    return ok and pid or nil
end

local function remove_lock_dir(path)
    if not path then return end
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and type(lfs.rmdir) == "function" then pcall(lfs.rmdir, path) end
end

local function parent_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 1 or not ffi then return true end
    local ok, result = pcall(function() return ffi.C.kill(pid, 0) end)
    return not ok or result == 0
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

function Service.run(job)
    job = job or {}
    local job_path = assert(job.job_path, "missing job path")
    local control_path = assert(job.control_path, "missing control path")
    local status_path = assert(job.status_path, "missing status path")
    local context_path = assert(job.context_path, "missing context path")
    local stop_path = assert(job.stop_path, "missing stop path")
    local owner_path = job.owner_path
    local lock_path = job.lock_path
    local parent_pid = tonumber(job.parent_pid)
    local poll_interval = math.max(0.5, tonumber(job.poll_interval) or 1)

    lower_priority()

    local generation = 0
    local sequence = 0
    local current_job = nil
    local book = {}
    local auth = {}
    local next_due = 0
    local last_control_state = nil

    write_status(status_path, {
        generation = 0,
        seq = 0,
        state = "service_waiting",
        started_at = os.time(),
    })

    while true do
        if U.file_exists(stop_path) or not parent_alive(parent_pid) then break end

        local control = read_json(control_path)
        if control and tonumber(control.generation or 0) ~= generation then
            local requested = tonumber(control.generation or 0) or 0
            local loaded = read_json(job_path)
            if loaded and tonumber(loaded.generation or 0) == requested then
                generation = requested
                current_job = loaded
                book = U.copy(loaded.book or {})
                auth = U.copy(loaded.auth or {})
                local interval = math.max(10, tonumber(loaded.interval) or 30)
                next_due = os.time() + interval
                last_control_state = nil
                U.atomic_write(context_path, Json.encode(book), true)
                write_status(status_path, {
                    generation = generation,
                    seq = sequence,
                    state = "waiting",
                    next_due = next_due,
                    book_id = tostring(loaded.book_id or ""),
                })
            end
        end

        if current_job and control and tonumber(control.generation or 0) == generation
            and tostring(control.controller_token or "") == tostring(current_job.controller_token or "")
        then
            local active = control.active == true
            local state_key = active and "active" or "inactive"
            if state_key ~= last_control_state then
                last_control_state = state_key
                if not active then
                    next_due = 0
                    write_status(status_path, {
                        generation = generation,
                        seq = sequence,
                        state = "inactive",
                        book_id = tostring(current_job.book_id or ""),
                    })
                elseif next_due <= 0 then
                    next_due = os.time() + math.max(10, tonumber(current_job.interval) or 30)
                end
            end

            if active then
                local now = os.time()
                local interval = math.max(10, tonumber(current_job.interval) or 30)
                local idle_timeout = math.max(interval, tonumber(current_job.idle_timeout) or 600)
                local last_activity = tonumber(control.last_activity) or now
                local idle = now - last_activity

                if now >= next_due then
                    if idle <= idle_timeout then
                        sequence = sequence + 1
                        local report_job = {
                            book_id = tostring(current_job.book_id or ""),
                            book_title = tostring(current_job.book_title or current_job.book_id or ""),
                            book = book,
                            progress_ratio = tonumber(control.progress_ratio) or 0,
                            elapsed_seconds = interval,
                            cookies = auth.cookies or {},
                            api_key = auth.api_key or "",
                            wr_ticket = auth.wr_ticket or "",
                            wr_wrpa = auth.wr_wrpa or "",
                            allow_renewal = false,
                        }
                        local attempted_at = now
                        local ok, result = pcall(Adapter.run, report_job)
                        local completed_at = os.time()

                        if ok and type(result) == "table" then
                            if type(result.legacy_context) == "table" then
                                book = U.copy(result.legacy_context)
                                if result.context_changed then
                                    U.atomic_write(context_path, Json.encode(book), true)
                                end
                            end
                            if result.cookies_changed and type(result.cookies) == "table" then auth.cookies = U.copy(result.cookies) end
                            if result.wr_ticket_changed then auth.wr_ticket = result.wr_ticket or "" end
                            if result.wr_wrpa_changed then auth.wr_wrpa = result.wr_wrpa or "" end

                            local out = public_result(result)
                            out.generation = generation
                            out.seq = sequence
                            out.state = result.accepted and "waiting" or "error"
                            out.attempted_at = attempted_at
                            out.completed_at = completed_at
                            out.next_due = completed_at + interval
                            out.book_id = tostring(current_job.book_id or "")
                            write_status(status_path, out)
                            next_due = out.next_due
                        else
                            next_due = completed_at + interval
                            write_status(status_path, {
                                generation = generation,
                                seq = sequence,
                                state = "error",
                                accepted = false,
                                error = tostring(result or "read report service failed"),
                                attempted_at = attempted_at,
                                completed_at = completed_at,
                                next_due = next_due,
                                book_id = tostring(current_job.book_id or ""),
                            })
                        end
                    else
                        next_due = now + interval
                    end
                end
            end
        end

        sleep(poll_interval)
    end

    write_status(status_path, {
        generation = generation,
        seq = sequence,
        state = "service_stopped",
        stopped_at = os.time(),
    })
    if owner_path then
        local owner = read_json(owner_path)
        if not owner or tonumber(owner.pid) == own_pid() then os.remove(owner_path) end
    end
    remove_lock_dir(lock_path)
    return true
end

return Service
