local Legacy = require("miuread.legacy.read_report_worker")

local Adapter = {}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do
        if type(item) ~= "function" and type(item) ~= "userdata" and type(item) ~= "thread" then
            out[copy(key, seen)] = copy(item, seen)
        end
    end
    return out
end

local function merge(base, patch)
    local out = copy(base or {})
    for key, value in pairs(patch or {}) do out[key] = copy(value) end
    return out
end

local function normalize_ratio(value)
    value = tonumber(value) or 0
    if value > 1 then value = value / 100 end
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function position(context, ratio)
    local chapters = type(context.chapters) == "table" and context.chapters or {}
    ratio = normalize_ratio(ratio)
    local selected, within
    if #chapters > 0 then
        local scaled = ratio * #chapters
        local index = math.floor(scaled) + 1
        if index < 1 then index = 1 elseif index > #chapters then index = #chapters end
        selected = chapters[index]
        within = scaled - math.floor(scaled)
        if index == #chapters and ratio >= 1 then within = 1 end
    end
    local words = tonumber(selected and selected.wordCount) or tonumber(context.chapter_word_count) or 0
    local offset = tonumber(context.chapter_offset) or 0
    if words > 0 and within then offset = math.floor(within * words) end
    return {
        progress = math.floor(ratio * 100 + 0.5),
        chapter_uid = selected and selected.chapterUid or context.chapter_uid or 0,
        chapter_index = tonumber(selected and selected.chapterIdx) or tonumber(context.chapter_idx) or 0,
        offset = offset,
    }
end

function Adapter.run(job)
    job = job or {}
    local legacy_job = {
        book_id = job.book_id,
        book_title = job.book_title,
        book = copy(job.book or {}),
        progress_ratio = job.progress_ratio,
        elapsed_seconds = job.elapsed_seconds,
        cookies = copy(job.cookies or {}),
        api_key = job.api_key or "",
        wr_ticket = job.wr_ticket or "",
        wr_wrpa = job.wr_wrpa or "",
        allow_renewal = job.allow_renewal == true,
    }
    local result = Legacy.run(legacy_job)
    local context = merge(legacy_job.book, result.book_patch)
    local path = "legacy_0.3.6.7_" .. tostring(result.path or result.error_kind or "unknown")
    return {
        accepted = result.ok == true,
        response = result.result or {},
        error = result.error,
        error_kind = result.error_kind,
        path = path,
        legacy_context = context,
        context_changed = result.context_changed == true,
        position = position(context, job.progress_ratio),
        cookies_changed = result.cookies_changed == true,
        cookies = result.cookies,
        wr_ticket_changed = result.wr_ticket_changed == true,
        wr_ticket = result.wr_ticket,
        wr_wrpa_changed = result.wr_wrpa_changed == true,
        wr_wrpa = result.wr_wrpa,
        response_summary = result.ok == true and "succ=1 (0.3.6.7 original path)"
            or tostring(result.error or "0.3.6.7 original path rejected"),
        attempts = { { stage = tostring(result.path or "legacy") } },
        payload_public = { legacy_original = true },
    }
end

return Adapter
