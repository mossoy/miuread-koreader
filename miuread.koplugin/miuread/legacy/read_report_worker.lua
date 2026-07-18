local Cookie = require("miuread.legacy.cookie")
local Client = require("miuread.legacy.client")
local Content = require("miuread.legacy.content")
local WeRead = require("miuread.legacy.weread")

local Worker = {}

local CONTEXT_MAX_AGE_SECONDS = 15 * 60

local function deepcopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do
        local key_type = type(key)
        local item_type = type(item)
        if (key_type == "string" or key_type == "number")
            and item_type ~= "function" and item_type ~= "userdata" and item_type ~= "thread" then
            out[deepcopy(key, seen)] = deepcopy(item, seen)
        end
    end
    return out
end

local MemorySettings = {}
MemorySettings.__index = MemorySettings

function MemorySettings:new(snapshot)
    return setmetatable({ data = deepcopy(snapshot or {}), changed = {} }, self)
end

function MemorySettings:get(key, default)
    local value = self.data[key]
    if value == nil then
        return deepcopy(default)
    end
    return deepcopy(value)
end

function MemorySettings:set(key, value)
    self.data[key] = deepcopy(value)
    self.changed[key] = true
end

function MemorySettings:flush()
    -- The worker is intentionally isolated from KOReader's persistent settings.
    -- Updated cookies/context are returned to the parent process and committed there.
end

function MemorySettings:is_cookie_configured()
    return Cookie.has_login_cookie(self.data.cookies or {})
end

local function normalize_progress_ratio(value)
    value = tonumber(value)
    if not value then
        return nil
    end
    if value > 1 then
        value = value / 100
    end
    if value < 0 then
        value = 0
    elseif value > 1 then
        value = 1
    end
    return value
end

local function read_report_accepted(result)
    return type(result) == "table"
        and (result.succ == true or tonumber(result.succ) == 1)
end

local function result_summary(result)
    if type(result) ~= "table" then
        return "non_table_response"
    end
    local parts = {
        "succ=" .. tostring(result.succ),
        "has_synckey=" .. tostring(result.synckey ~= nil),
    }
    local err_code = result.errCode or result.errcode or result.code
    local err_message = result.errMsg or result.errmsg or result.message or result.msg
    if err_code ~= nil then
        parts[#parts + 1] = "error_code=" .. tostring(err_code)
    end
    if err_message ~= nil then
        parts[#parts + 1] = "error_message="
            .. tostring(err_message):gsub("[%c]+", " "):sub(1, 160)
    end
    return table.concat(parts, ", ")
end

local function confirmation(result)
    if type(result) ~= "table" then
        return { succ = 0 }
    end
    return {
        succ = result.succ,
        synckey = result.synckey,
    }
end

local function book_record(books, book_id)
    if type(books) ~= "table" then
        return nil
    end
    return books[tostring(book_id)] or books[book_id]
end

local function select_context_chapter(book)
    local chapters = type(book.chapters) == "table" and book.chapters or {}
    local selected

    if book.chapter_uid ~= nil then
        for _, chapter in ipairs(chapters) do
            if tostring(chapter.chapterUid or "") == tostring(book.chapter_uid) then
                selected = chapter
                break
            end
        end
    end

    if not selected and #chapters > 0 then
        local ratio = normalize_progress_ratio(book.progress) or 0
        local index = math.floor(ratio * #chapters) + 1
        if index < 1 then
            index = 1
        elseif index > #chapters then
            index = #chapters
        end
        selected = chapters[index]
    end

    return selected or Content.first_readable_chapter(chapters)
end

local function refresh_context(client, book_id, book, force)
    book_id = tostring(book_id or "")
    if book_id == "" then
        error("missing book id")
    end

    book = deepcopy(book or {})
    book.book_id = book.book_id or book.bookId or book_id
    book.title = book.title or book_id
    book.reader_url = book.reader_url or WeRead.reader_url(book_id)

    local now = os.time()
    local context_age = now - (tonumber(book.read_context_updated_at) or 0)
    local context_ready = book.psvts ~= nil and tostring(book.psvts) ~= ""
        and book.chapter_uid ~= nil
        and type(book.chapters) == "table" and #book.chapters > 0

    if not force and context_ready and context_age < CONTEXT_MAX_AGE_SECONDS then
        return book, false
    end

    Content.ensure_reader_state(client, book)

    if force or type(book.chapters) ~= "table" or #book.chapters == 0 then
        Content.fetch_catalog(client, book)
    end

    local progress_ok, progress_result = pcall(function()
        return client:get_progress(book_id)
    end)
    if progress_ok and type(progress_result) == "table" then
        local remote = type(progress_result.book) == "table"
            and progress_result.book or progress_result
        book.progress = tonumber(remote.progress) or tonumber(book.progress) or 0
        book.chapter_uid = remote.chapterUid or remote.chapterId
            or remote.chapter_uid or book.chapter_uid
        book.chapter_idx = tonumber(remote.chapterIdx or remote.chapterIndex or remote.chapter_idx)
            or tonumber(book.chapter_idx)
        book.chapter_offset = tonumber(remote.chapterOffset or remote.chapterPos or remote.offset)
            or tonumber(book.chapter_offset) or 0
    end

    local selected = select_context_chapter(book)
    if not selected then
        error("no readable chapter found for report context")
    end

    book.chapter_uid = selected.chapterUid or book.chapter_uid
    book.chapter_idx = tonumber(selected.chapterIdx) or tonumber(book.chapter_idx) or 0
    book.chapter_word_count = tonumber(selected.wordCount)
        or tonumber(book.chapter_word_count) or 0
    book.app_id = book.app_id or WeRead.web_app_id()
    book.read_context_updated_at = now
    book.read_context_ready = book.psvts ~= nil and tostring(book.psvts) ~= ""
        and book.chapter_uid ~= nil

    if not book.read_context_ready then
        error("reader context is incomplete")
    end
    return book, true
end

local function estimate_position(book, progress_ratio)
    local chapters = type(book.chapters) == "table" and book.chapters or {}
    local ratio = normalize_progress_ratio(progress_ratio)
        or normalize_progress_ratio(book.progress)
        or 0

    local chapter
    local within_chapter = 0
    if #chapters > 0 then
        local scaled = ratio * #chapters
        local index = math.floor(scaled) + 1
        if index < 1 then
            index = 1
        elseif index > #chapters then
            index = #chapters
        end
        chapter = chapters[index]
        within_chapter = scaled - math.floor(scaled)
        if index == #chapters and ratio >= 1 then
            within_chapter = 1
        end
    end

    if not chapter and book.chapter_uid ~= nil then
        for _, item in ipairs(chapters) do
            if tostring(item.chapterUid or "") == tostring(book.chapter_uid) then
                chapter = item
                break
            end
        end
    end

    local chapter_uid = chapter and chapter.chapterUid or book.chapter_uid or 0
    local chapter_idx = tonumber(chapter and chapter.chapterIdx)
        or tonumber(book.chapter_idx) or 0
    local word_count = tonumber(chapter and chapter.wordCount)
        or tonumber(book.chapter_word_count) or 0
    local chapter_offset = tonumber(book.chapter_offset) or 0
    if word_count > 0 then
        chapter_offset = math.floor(within_chapter * word_count)
    end

    return {
        chapter_uid = chapter_uid,
        chapter_idx = chapter_idx,
        chapter_offset = chapter_offset,
        progress = math.floor(ratio * 100 + 0.5),
    }
end

local function build_payload(book_id, elapsed_seconds, book, progress_ratio)
    local position = estimate_position(book, progress_ratio)
    return WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = position.chapter_uid,
        chapter_idx = position.chapter_idx,
        chapter_offset = position.chapter_offset,
        progress = position.progress,
        summary = book.summary or "",
        elapsed_seconds = elapsed_seconds,
        app_id = book.app_id or WeRead.web_app_id(),
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
    }
end

local function attempt_report(client, book_id, elapsed_seconds, book, progress_ratio)
    local payload = build_payload(book_id, elapsed_seconds, book, progress_ratio)
    local referer = book.reader_url or WeRead.reader_url(book_id)
    local ok, result = pcall(function()
        return client:report_read(payload, referer)
    end)
    if not ok then
        return false, nil, tostring(result), "transport"
    end
    if read_report_accepted(result) then
        return true, result
    end
    return false, result, result_summary(result), "server"
end

local BOOK_PATCH_KEYS = {
    "book_id", "bookId", "title", "author", "reader_url",
    "psvts", "pclts", "token", "chapters", "progress",
    "chapter_uid", "chapter_idx", "chapter_offset", "chapter_word_count",
    "app_id", "read_context_updated_at", "read_context_ready",
}

local function make_book_patch(book)
    local patch = {}
    for _, key in ipairs(BOOK_PATCH_KEYS) do
        if book and book[key] ~= nil then
            patch[key] = deepcopy(book[key])
        end
    end
    return patch
end

local function finish(settings, book, fields, context_changed)
    fields = fields or {}
    if settings.changed.cookies then
        fields.cookies_changed = true
        fields.cookies = settings:get("cookies", {})
    end
    if settings.changed.wr_ticket then
        fields.wr_ticket_changed = true
        fields.wr_ticket = settings:get("wr_ticket", "")
    end
    if settings.changed.wr_wrpa then
        fields.wr_wrpa_changed = true
        fields.wr_wrpa = settings:get("wr_wrpa", "")
    end
    if context_changed then
        fields.context_changed = true
        fields.book_patch = make_book_patch(book)
    end
    return fields
end

function Worker.run(job)
    job = job or {}
    local book_id = tostring(job.book_id or "")
    local elapsed_seconds = tonumber(job.elapsed_seconds) or 30
    local progress_ratio = normalize_progress_ratio(job.progress_ratio)
    local settings = MemorySettings:new{
        cookies = job.cookies or {},
        api_key = job.api_key or "",
        wr_ticket = job.wr_ticket or "",
        wr_wrpa = job.wr_wrpa or "",
        books = {},
    }
    local client = Client:new(settings)
    local book = deepcopy(job.book or {})
    local context_changed = false
    book.book_id = book.book_id or book.bookId or book_id
    book.title = book.title or job.book_title or book_id

    if book_id == "" then
        return finish(settings, book, {
            ok = false,
            error = "missing book id",
            error_kind = "context",
        }, context_changed)
    end
    if not settings:is_cookie_configured() then
        return finish(settings, book, {
            ok = false,
            error = "cookie not configured",
            error_kind = "authentication",
        }, context_changed)
    end

    local context_ok, context_or_error, initial_context_changed = pcall(function()
        return refresh_context(client, book_id, book, false)
    end)
    if not context_ok then
        return finish(settings, book, {
            ok = false,
            error = tostring(context_or_error),
            error_kind = "context",
        }, context_changed)
    end
    book = context_or_error
    context_changed = initial_context_changed == true

    local accepted, result, first_error, first_kind = attempt_report(
        client, book_id, elapsed_seconds, book, progress_ratio
    )
    if accepted then
        return finish(settings, book, {
            ok = true,
            result = confirmation(result),
            path = "initial",
        }, context_changed)
    end
    if first_kind == "transport" then
        return finish(settings, book, {
            ok = false,
            error = first_error,
            error_kind = "transport",
        }, context_changed)
    end

    local first_failure = first_error
    local refresh_ok, refreshed_or_error, refreshed_changed = pcall(function()
        return refresh_context(client, book_id, book, true)
    end)
    if refresh_ok then
        book = refreshed_or_error
        context_changed = context_changed or refreshed_changed == true
        local retry_accepted, retry_result, retry_error = attempt_report(
            client, book_id, elapsed_seconds, book, progress_ratio
        )
        if retry_accepted then
            return finish(settings, book, {
                ok = true,
                result = confirmation(retry_result),
                path = "context_refresh",
        }, context_changed)
        end
        first_failure = "initial=" .. tostring(first_failure)
            .. "; refreshed=" .. tostring(retry_error)
    else
        first_failure = tostring(first_failure)
            .. "; context_refresh=" .. tostring(refreshed_or_error)
    end

    if job.allow_renewal ~= true then
        return finish(settings, book, {
            ok = false,
            error = first_failure,
            error_kind = "server",
        }, context_changed)
    end

    local renew_ok, renew_result = pcall(function()
        return client:renew_cookie()
    end)
    if not renew_ok or not read_report_accepted(renew_result) then
        local renewal_error = renew_ok and result_summary(renew_result) or tostring(renew_result)
        return finish(settings, book, {
            ok = false,
            error = first_failure .. "; renewal=" .. renewal_error,
            error_kind = "authentication",
            renewal_attempted = true,
        }, context_changed)
    end

    local final_context_ok, final_book_or_error, final_context_changed = pcall(function()
        return refresh_context(client, book_id, book, true)
    end)
    if not final_context_ok then
        return finish(settings, book, {
            ok = false,
            error = first_failure .. "; final_context=" .. tostring(final_book_or_error),
            error_kind = "context",
            renewal_attempted = true,
        }, context_changed)
    end
    book = final_book_or_error
    context_changed = context_changed or final_context_changed == true

    local final_accepted, final_result, final_error, final_kind = attempt_report(
        client, book_id, elapsed_seconds, book, progress_ratio
    )
    if final_accepted then
        return finish(settings, book, {
            ok = true,
            result = confirmation(final_result),
            path = "cookie_renewal",
            renewal_attempted = true,
        }, context_changed)
    end

    return finish(settings, book, {
        ok = false,
        error = first_failure .. "; final=" .. tostring(final_error),
        error_kind = final_kind or "server",
        renewal_attempted = true,
        }, context_changed)
end

return Worker
