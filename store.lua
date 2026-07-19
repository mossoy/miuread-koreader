local Protocol = require("miuread.protocol")
local U = require("miuread.util")

local Worker = {}

local CONTEXT_MAX_AGE_SECONDS = 15 * 60

local function copy(value)
    return U.copy(value or {})
end

local function normalize_ratio(value)
    value = tonumber(value)
    if not value then return nil end
    if value > 1 then value = value / 100 end
    return U.clamp(value, 0, 1)
end

local function accepted(value)
    return type(value) == "table" and (value.succ == true or tonumber(value.succ) == 1)
end

local function response_summary(value, meta)
    local rows = {}
    if type(meta) == "table" then
        if meta.code then rows[#rows + 1] = "HTTP=" .. tostring(meta.code) end
        if meta.length then rows[#rows + 1] = "bytes=" .. tostring(meta.length) end
        if meta.content_type then rows[#rows + 1] = "type=" .. tostring(meta.content_type) end
    end
    if type(value) ~= "table" then
        rows[#rows + 1] = "non-table-response"
        return table.concat(rows, ", ")
    end
    rows[#rows + 1] = accepted(value) and "succ=1" or "succ=not-found"
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    if #keys > 0 then rows[#rows + 1] = "keys=" .. table.concat(keys, "|") end
    local code = value.errCode or value.errcode or value.code
    local message = value.errMsg or value.errmsg or value.message or value.msg
    if code ~= nil then rows[#rows + 1] = "code=" .. tostring(code) end
    if message ~= nil then rows[#rows + 1] = "message=" .. U.first_line(message, 140) end
    return table.concat(rows, ", ")
end

local function catalog_rows(catalog)
    if type(catalog) ~= "table" then return {} end
    return catalog.updated or catalog.chapterInfos or catalog.chapters or {}
end

local function readable_chapters(catalog)
    local rows = {}
    for _, chapter in ipairs(catalog_rows(catalog)) do
        local words = tonumber(chapter.wordCount or chapter.word_count or 0) or 0
        local title = tostring(chapter.title or "")
        if words > 0 and title ~= "封面" then
            rows[#rows + 1] = {
                uid = chapter.chapterUid or chapter.uid,
                index = tonumber(chapter.chapterIdx or chapter.index) or #rows + 1,
                title = title,
                word_count = words,
            }
        end
    end
    return rows
end

local function progress_node(value, depth, seen)
    if type(value) ~= "table" or (depth or 0) > 6 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local p = tonumber(value.progress or value.readingProgress or value.bookProgress or value.progressPercent)
    if p then
        if p > 1 then p = p / 100 end
        return {
            ratio = U.clamp(p, 0, 1),
            chapter_uid = value.chapterUid or value.chapterId or value.chapter_uid,
            chapter_index = tonumber(value.chapterIdx or value.chapterIndex or value.chapter_idx),
            offset = tonumber(value.chapterOffset or value.chapterPos or value.offset),
        }
    end
    for _, key in ipairs({"book", "data", "result", "payload", "progressInfo", "reader"}) do
        local found = progress_node(value[key], (depth or 0) + 1, seen)
        if found then return found end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local found = progress_node(child, (depth or 0) + 1, seen)
            if found then return found end
        end
    end
end

local function select_context_chapter(book)
    local chapters = type(book.chapters) == "table" and book.chapters or {}
    if book.chapter_uid ~= nil then
        for _, chapter in ipairs(chapters) do
            if tostring(chapter.uid or "") == tostring(book.chapter_uid) then return chapter end
        end
    end
    if #chapters > 0 then
        local ratio = normalize_ratio(book.progress) or 0
        local index = math.floor(ratio * #chapters) + 1
        index = math.max(1, math.min(#chapters, index))
        return chapters[index]
    end
end

local function refresh_context(reader, api, book_id, book, force)
    book = copy(book)
    book.book_id = tostring(book.book_id or book_id or "")
    if book.book_id == "" then error("missing book id") end
    book.reader_url = book.reader_url or Protocol.reader_url(book.book_id)

    local now = os.time()
    local age = now - (tonumber(book.context_updated_at or 0) or 0)
    local has_context = Protocol.optional(book.psvts) ~= nil
        and type(book.chapters) == "table" and #book.chapters > 0
    -- A context captured during download may not have an explicit timestamp in
    -- older MiuRead data. Try it once instead of forcing a cloud-progress call.
    if not force and has_context and ((tonumber(book.context_updated_at or 0) or 0) == 0
        or age < CONTEXT_MAX_AGE_SECONDS) then
        local selected = select_context_chapter(book)
        if selected then
            book.chapter_uid = selected.uid
            book.chapter_index = tonumber(selected.index) or 0
            book.chapter_word_count = tonumber(selected.word_count) or 0
        end
        return book, false
    end

    if force or not Protocol.optional(book.psvts) then
        local state = reader:state(book.book_id, nil)
        book.psvts = Protocol.optional(state.psvts) or Protocol.optional(book.psvts)
        book.pclts = Protocol.optional(state.pclts) or Protocol.optional(book.pclts)
        book.token = Protocol.optional(state.token) or Protocol.optional(book.token)
        book.reader_url = state.url or book.reader_url
    end

    if force or type(book.chapters) ~= "table" or #book.chapters == 0 then
        local ok_catalog, catalog = pcall(reader.catalog, reader, book.book_id)
        if ok_catalog then
            local chapters = readable_chapters(catalog)
            if #chapters > 0 then book.chapters = chapters end
        elseif type(book.chapters) ~= "table" or #book.chapters == 0 then
            error(catalog)
        end
    end

    -- Cloud reading progress is intentionally not read here. The local KOReader
    -- position is supplied by Worker.run and is used only to form the read-time
    -- request fields required by WeRead.
    local selected = select_context_chapter(book)
    if not selected then error("no readable chapter found for report context") end
    book.chapter_uid = selected.uid or book.chapter_uid
    book.chapter_index = tonumber(selected.index) or tonumber(book.chapter_index) or 0
    book.chapter_word_count = tonumber(selected.word_count) or tonumber(book.chapter_word_count) or 0
    book.app_id = book.app_id or Protocol.app_id(Protocol.USER_AGENT)
    book.context_updated_at = now
    if not Protocol.optional(book.psvts) or book.chapter_uid == nil then
        error("reader context is incomplete")
    end
    return book, true
end

local function estimate_position(book, progress_ratio)
    local chapters = type(book.chapters) == "table" and book.chapters or {}
    local ratio = normalize_ratio(progress_ratio) or normalize_ratio(book.progress) or 0
    local chapter, within = nil, 0
    if #chapters > 0 then
        local scaled = ratio * #chapters
        local index = math.floor(scaled) + 1
        index = math.max(1, math.min(#chapters, index))
        chapter = chapters[index]
        within = scaled - math.floor(scaled)
        if index == #chapters and ratio >= 1 then within = 1 end
    end
    if not chapter and book.chapter_uid ~= nil then
        for _, item in ipairs(chapters) do
            if tostring(item.uid or "") == tostring(book.chapter_uid) then chapter = item; break end
        end
    end
    local words = tonumber(chapter and chapter.word_count) or tonumber(book.chapter_word_count) or 0
    local offset = tonumber(book.chapter_offset) or 0
    if words > 0 then offset = math.floor(within * words) end
    return {
        chapter_uid = chapter and chapter.uid or book.chapter_uid or 0,
        chapter_index = tonumber(chapter and chapter.index) or tonumber(book.chapter_index) or 0,
        offset = offset,
        progress = math.floor(ratio * 100 + 0.5),
    }
end

local function build_payload(book_id, elapsed, book, progress_ratio)
    local position = estimate_position(book, progress_ratio)
    local payload, sources = Protocol.read_fields{
        book_id = book_id,
        chapter_uid = position.chapter_uid,
        chapter_index = position.chapter_index,
        chapter_offset = position.offset,
        progress = position.progress,
        summary = book.summary or "",
        elapsed = elapsed,
        app_id = book.app_id or Protocol.app_id(Protocol.USER_AGENT),
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
        user_agent = Protocol.USER_AGENT,
    }
    return payload, position, sources
end

local function attempt(reader, book_id, elapsed, book, progress_ratio, stage)
    local payload, position, sources = build_payload(book_id, elapsed, book, progress_ratio)
    local ok, value, meta = pcall(reader.report_payload, reader, payload,
        book.reader_url or Protocol.reader_url(book_id), 0)
    if not ok then
        return {accepted=false, transport=false, stage=stage, error=tostring(value), position=position,
            payload_public={ci=payload.ci, co=payload.co, pr=payload.pr, rt=payload.rt,
                token_source=sources.token_source, pc_source=sources.pc_source, ps_source=sources.ps_source,
                sg_ready=sources.sg_ready, payload_fields_complete=sources.payload_fields_complete}}
    end
    return {
        accepted=accepted(value), transport=true, stage=stage, response=value, meta=meta,
        summary=response_summary(value, meta), position=position,
        payload_public={ci=payload.ci, co=payload.co, pr=payload.pr, rt=payload.rt,
            token_source=sources.token_source, pc_source=sources.pc_source, ps_source=sources.ps_source,
            sg_ready=sources.sg_ready, payload_fields_complete=sources.payload_fields_complete},
    }
end

local function auth_error(text)
    text = tostring(text or ""):lower()
    return text:find("http 401", 1, true) or text:find("http 403", 1, true)
        or text:find("login expired", 1, true) or text:find("未登录", 1, true)
        or text:find("登录过期", 1, true)
end

function Worker.run(job)
    job = job or {}
    local reader, api = assert(job.reader), assert(job.api)
    local book_id = tostring(job.book_id or "")
    local elapsed = tonumber(job.elapsed) or 30
    local ratio = normalize_ratio(job.progress_ratio) or 0
    local book = copy(job.book)
    book.book_id = book.book_id or book_id
    book.title = book.title or job.book_title or book_id
    if job.disable_progress ~= false then
        book.progress = ratio
        book.chapter_uid = nil
        book.chapter_index = nil
        book.chapter_offset = nil
    end
    if book_id == "" then return {accepted=false,error="missing book id",path="context"} end

    local ok_context, context_or_error = pcall(refresh_context, reader, api, book_id, book, false)
    if not ok_context then return {accepted=false,error=tostring(context_or_error),path="context"} end
    book = context_or_error

    local attempts = {}
    local first = attempt(reader, book_id, elapsed, book, ratio, "initial")
    attempts[#attempts + 1] = first
    if first.accepted then
        return {accepted=true,path="initial",response=first.response,meta=first.meta,
            response_summary=first.summary,position=first.position,context=book,attempts=attempts,
            payload_public=first.payload_public}
    end
    if not first.transport then
        -- Authentication failures are handled separately. Empty JSON and other
        -- server rejections never renew cookies, avoiding multi-device churn.
        if auth_error(first.error) and job.allow_renewal == true then
            local renew_ok, renew_value, renew_meta = pcall(reader.renew, reader)
            attempts[#attempts + 1] = {stage="cookie_renewal",transport=renew_ok,
                summary=renew_ok and response_summary(renew_value, renew_meta) or tostring(renew_value)}
        else
            return {accepted=false,error=first.error,path="transport",context=book,
                position=first.position,attempts=attempts,payload_public=first.payload_public}
        end
    end

    -- Empty JSON is a signed-request rejection, not an authentication signal.
    -- Rebuild the reader context once, but never mutate login cookies here.
    local ok_refresh, refreshed_or_error = pcall(refresh_context, reader, api, book_id, book, true)
    if not ok_refresh then
        return {accepted=false,error=(first.summary or first.error or "rejected")
            .. "; context_refresh=" .. tostring(refreshed_or_error),path="context_refresh_failed",
            context=book,position=first.position,attempts=attempts,payload_public=first.payload_public}
    end
    book = refreshed_or_error
    local second = attempt(reader, book_id, elapsed, book, ratio, "compatibility_retry")
    attempts[#attempts + 1] = second
    if second.accepted then
        return {accepted=true,path="compatibility_retry",response=second.response,meta=second.meta,
            response_summary=second.summary,position=second.position,context=book,attempts=attempts,
            payload_public=second.payload_public}
    end
    return {accepted=false,error="initial=" .. tostring(first.summary or first.error or "rejected")
        .. "; compatibility_retry=" .. tostring(second.summary or second.error or "rejected"),
        path="rejected",context=book,position=second.position,attempts=attempts,
        response_summary=second.summary,meta=second.meta,payload_public=second.payload_public}
end

Worker._estimate_position = estimate_position
Worker._accepted = accepted
Worker._refresh_context = refresh_context
return Worker
