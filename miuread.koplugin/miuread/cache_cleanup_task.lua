local FFIUtil = require("ffi/util")
local Json = require("miuread.json")
local U = require("miuread.util")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local CacheCleanupTask = {}
CacheCleanupTask.__index = CacheCleanupTask

local function clean_paths(paths)
    local out, seen = {}, {}
    for _, path in ipairs(paths or {}) do
        path = tostring(path or "")
        if path ~= "" and not seen[path] then
            seen[path] = true
            out[#out + 1] = path
        end
    end
    return out
end

function CacheCleanupTask:new(store)
    return setmetatable({store = store, job = nil, poll_task = nil}, self)
end

function CacheCleanupTask:available()
    return type(FFIUtil.runInSubProcess) == "function"
        and type(FFIUtil.isSubProcessDone) == "function"
end

function CacheCleanupTask:busy()
    return self.job ~= nil
end

function CacheCleanupTask:_schedule()
    if self.poll_task then return end
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    UIManager:scheduleIn(0.20, task)
end

function CacheCleanupTask:_finish(job, forced_error)
    local raw = U.read_file(job.result_path, true)
    local result
    if forced_error then
        result = {ok = false, error = forced_error}
    elseif not raw then
        result = {ok = false, error = "清理进程异常退出"}
    else
        local ok, decoded = pcall(Json.decode, raw)
        result = ok and decoded or {ok = false, error = "清理结果无法解析"}
    end
    os.remove(job.result_path)
    self.job = nil
    if job.on_done then job.on_done(result) end
end

function CacheCleanupTask:_poll()
    local job = self.job
    if not job then return end
    if os.time() - job.started_at > job.timeout then
        pcall(FFIUtil.terminateSubProcess, job.pid)
        self:_finish(job, "清理超时")
        return
    end
    local ok, done = pcall(FFIUtil.isSubProcessDone, job.pid, false)
    if not ok then
        logger.warn("[MiuRead][CacheCleanup] poll failed", tostring(done))
        self:_schedule()
        return
    end
    if not done then
        self:_schedule()
        return
    end
    self:_finish(job)
end

function CacheCleanupTask:start(paths, on_done)
    if self.job then return false, "已有缓存清理任务正在运行" end
    if not self:available() then return false, "当前 KOReader 不支持后台清理" end
    paths = clean_paths(paths)
    if #paths == 0 then
        if on_done then on_done({ok = true, removed = 0, errors = {}}) end
        return true
    end

    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    local result_path = self.store.temp_dir .. "/cache-cleanup-" .. stamp .. ".json"
    local child_paths = U.copy(paths)
    local child = function()
        local JsonChild = require("miuread.json")
        local UChild = require("miuread.util")
        local errors = {}
        local removed = 0
        for _, path in ipairs(child_paths) do
            local ok, err = UChild.remove_tree(path)
            if ok then
                removed = removed + 1
            else
                errors[#errors + 1] = tostring(path) .. "：" .. tostring(err or "删除失败")
            end
        end
        local payload = {
            ok = #errors == 0,
            removed = removed,
            errors = errors,
            error = #errors > 0 and table.concat(errors, "\n") or nil,
        }
        local encoded = JsonChild.encode(payload)
        UChild.atomic_write(result_path, encoded, true)
    end

    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then return false, tostring(err or pid or "无法启动缓存清理") end
    self.job = {
        pid = pid,
        result_path = result_path,
        on_done = on_done,
        started_at = os.time(),
        timeout = 300,
    }
    self:_schedule()
    return true
end

return CacheCleanupTask
