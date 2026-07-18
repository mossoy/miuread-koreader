local Json = require("miuread.json")
local Protocol = require("miuread.protocol")
local Cookies = require("miuread.cookies")
local Codec = require("miuread.codec")
local Util = require("miuread.util")
local logger = require("logger")
local ok_socket, socket = pcall(require, "socket")

local Reader = {}
Reader.__index = Reader
local BASE = "https://weread.qq.com"

local PART_CSS = [[
.miu-part-page {
    min-height: 78vh;
    display: block;
    text-align: center;
    page-break-before: always;
    break-before: page;
}
.miu-part-page .miu-part-title {
    margin: 34vh 0 0 0;
    font-size: 1.9em;
    font-weight: bold;
    line-height: 1.4;
    text-align: center;
}
]]

local function pause(seconds)
    if ok_socket and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
    end
end

local function scalar(value)
    if type(value) == "string" or type(value) == "number" then return value end
end

local function optional_value(value)
    value = scalar(value)
    if value == nil then return nil end
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = value:lower()
    if value == "" or lower == "null" or lower == "undefined" then return nil end
    return value
end

local function find_context(value, depth, seen)
    if type(value) ~= "table" or (depth or 0) > 7 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local psvts = optional_value(value.psvts)
    local pclts = optional_value(value.pclts)
    local token = optional_value(value.token)
    if psvts or pclts or token then
        return {psvts=psvts, pclts=pclts, token=token, book=value.bookInfo or value.book or {}}
    end
    for _, key in ipairs({"reader", "data", "result", "state", "readerState", "initialState", "payload", "book"}) do
        local found = find_context(value[key], (depth or 0) + 1, seen)
        if found then return found end
    end
    for _, item in pairs(value) do
        if type(item) == "table" then
            local found = find_context(item, (depth or 0) + 1, seen)
            if found then return found end
        end
    end
end

local function regex_context(html)
    return {
        psvts = optional_value(html:match('"psvts"%s*:%s*"([^"]+)"') or html:match('"psvts"%s*:%s*(%d+)')),
        pclts = optional_value(html:match('"pclts"%s*:%s*"([^"]+)"') or html:match('"pclts"%s*:%s*(%d+)')),
        token = optional_value(html:match('"token"%s*:%s*"([^"]+)"')),
        book = {},
    }
end

local function catalog_records(data)
    local current = data
    for _ = 1, 4 do
        if type(current) ~= "table" then break end
        if current.bookId or current.updated or current.chapterInfos or current.chapters then return {current} end
        if #current > 0 then return current end
        local next_value = current.data or current.result or current.payload
        if type(next_value) ~= "table" then break end
        current = next_value
    end
    return type(current) == "table" and current or {}
end

local function visible_text(html)
    return tostring(html or ""):gsub("<script.-</script>", " "):gsub("<style.-</style>", " ")
        :gsub("<[^>]+>", " "):gsub("&[%#%w]+;", " "):gsub("%s+", "")
end

local function compact_title(value)
    return tostring(value or ""):gsub("<[^>]+>", ""):gsub("[%s%p%c]", "")
end

local function truthy(value)
    return value == true or value == 1 or value == "1" or value == "true"
end

local function is_structure_chapter(chapter)
    chapter = type(chapter) == "table" and chapter or {}
    if truthy(chapter.isPart) or truthy(chapter.isVolume) or truthy(chapter.isTitle)
        or truthy(chapter.isSection) or truthy(chapter.isDivider) then
        return true
    end

    local kind = tostring(chapter.chapterType or chapter.chapter_type or chapter.typeName or chapter.nodeType or ""):lower()
    if kind:find("part", 1, true) or kind:find("volume", 1, true)
        or kind:find("divider", 1, true) or kind:find("section_title", 1, true) then
        return true
    end

    local words = tonumber(chapter.wordCount or chapter.word_count)
    if not words or words > 120 then return false end
    local title = compact_title(chapter.title)
    if title == "" then return false end

    if title:sub(1, #"第") == "第" then
        for _, marker in ipairs({"部", "卷", "编", "篇", "辑", "册"}) do
            local pos = title:find(marker, #"第" + 1, true)
            if pos and pos <= 24 then return true end
        end
    end
    local exact = {
        ["上部"]=true, ["中部"]=true, ["下部"]=true,
        ["上卷"]=true, ["中卷"]=true, ["下卷"]=true,
        ["上篇"]=true, ["中篇"]=true, ["下篇"]=true,
        ["上编"]=true, ["中编"]=true, ["下编"]=true,
        ["前篇"]=true, ["后篇"]=true,
    }
    return exact[title] == true
end

local function structure_xhtml(title)
    return '<div class="miu-part-page" data-miuread-structure="1"><h1 class="miu-part-title">'
        .. Util.xml(title or "分部") .. "</h1></div>"
end

local function is_empty_error(value)
    local text = tostring(value or ""):lower()
    return text:find("decoded epub chapter is empty", 1, true)
        or text:find("decoded txt chapter is empty", 1, true)
        or text:find("returned empty content", 1, true)
        or text:find("chapter content is empty", 1, true)
end

local function is_auth_error(value)
    local text = tostring(value or ""):lower()
    return text:find("http 401", 1, true) or text:find("http 403", 1, true)
        or text:find("login expired", 1, true) or text:find("not logged", 1, true)
        or text:find("未登录", 1, true) or text:find("登录过期", 1, true)
end

function Reader:new(http, store) return setmetatable({http=http, store=store}, self) end

function Reader:renew()
    local data, _, meta = self.http:post_json(BASE .. "/web/login/renewal", {rq="%2Fweb%2Fbook%2Fread", ql=false},
        {headers={Origin=BASE, Referer=BASE .. "/", Accept="application/json, text/plain, */*"}, retries=2})
    return data, meta
end

function Reader:state(book_id, chapter_uid)
    local url = Protocol.is_mp(book_id) and Protocol.mp_reader_url(book_id) or Protocol.reader_url(book_id, chapter_uid)
    local html = self.http:download(url, {headers={Accept="text/html,application/xhtml+xml"}, retries=3})
    -- 0.3.6.7 used the top-level reader-page fields directly. Prefer that
    -- exact path before recursively searching nested JSON nodes, which may
    -- contain stale preview/session objects with different tokens.
    local context = regex_context(html)
    if not optional_value(context.psvts) then
        local raw = Util.extract_balanced_json(html, "window.__INITIAL_STATE__")
            or Util.extract_balanced_json(html, "__INITIAL_STATE__")
        if raw then
            local ok, data = pcall(Json.decode, raw)
            if ok then context = find_context(data) or context end
        end
    end
    context.url = url
    if not optional_value(context.psvts) then error("reader.psvts not found") end
    return context
end

function Reader:catalog(book_id)
    local data = self.http:post_json(BASE .. "/web/book/chapterInfos", {bookIds={tostring(book_id)}},
        {headers={Origin=BASE, Referer=Protocol.reader_url(book_id)}, retries=3})
    local records = catalog_records(data)
    for _, record in ipairs(records or {}) do
        if tostring(record.bookId or "") == tostring(book_id) then return record end
    end
    if #records == 1 and type(records[1]) == "table" then return records[1] end
    error("book catalog not returned")
end

function Reader:shard(path, book_id, chapter_uid, psvts, style)
    local body = Protocol.content_fields(book_id, chapter_uid, psvts, style)
    local raw, code = self.http:request{
        url=BASE .. path, method="POST", body=Json.encode(body), retries=3,
        headers={Origin=BASE, Referer=Protocol.reader_url(book_id, chapter_uid), ["Content-Type"]="application/json;charset=UTF-8"},
    }
    if code < 200 or code >= 300 then error(path .. " failed: HTTP " .. tostring(code)) end
    if not raw or raw == "{}" or #raw < 8 then error(path .. " returned empty content") end
    return raw
end

function Reader:_txt_once(book, chapter, opt, state)
    opt = opt or {}
    local id = tostring(book.bookId or book.book_id)
    local uid = chapter.chapterUid or chapter.uid
    state = state or self:state(id, uid)
    local a = self:shard("/web/book/chapter/t_0", id, uid, state.psvts, false)
    local ok_b, b = pcall(self.shard, self, "/web/book/chapter/t_1", id, uid, state.psvts, false)
    if not ok_b then b = "" end
    local xhtml = Codec.text_xhtml(Codec.decode_parts({a, b}))
    if #visible_text(xhtml) < 8 then error("decoded TXT chapter is empty") end
    state.content_format = "txt"
    return xhtml, "body{line-height:1.75;margin:5%;}", {}, state
end

function Reader:_epub_once(book, chapter, opt, state)
    opt = opt or {}
    local id = tostring(book.bookId or book.book_id)
    local uid = chapter.chapterUid or chapter.uid
    state = state or self:state(id, uid)

    local a = self:shard("/web/book/chapter/e_0", id, uid, state.psvts, false)
    if a:match("^%s*{") and a:find('"bookId"', 1, true) then
        return self:_txt_once(book, chapter, opt, state)
    end
    local b = self:shard("/web/book/chapter/e_1", id, uid, state.psvts, false)
    local c = self:shard("/web/book/chapter/e_3", id, uid, state.psvts, false)
    local xhtml = Codec.decode_parts({a, b, c})
    if #visible_text(xhtml) < 8 then error("decoded EPUB chapter is empty") end

    local css = "body{line-height:1.7;margin:5%;}img{max-width:100%;height:auto;}"
    local ok_style, style_raw = pcall(self.shard, self, "/web/book/chapter/e_2", id, uid, state.psvts, true)
    if ok_style and not style_raw:match("^%s*{") then
        local ok, value = pcall(Codec.decode_parts, {style_raw})
        if ok and value ~= "" then css = value end
    end

    local assets = {}
    local tar_url = chapter.tar
    if opt.images ~= false and tar_url and tar_url ~= "" then
        if tar_url:sub(1, 2) == "//" then tar_url = "https:" .. tar_url elseif tar_url:sub(1, 1) == "/" then tar_url = BASE .. tar_url end
        local blob = self.http:download(tar_url, {headers={Referer=state.url}, retries=3})
        for name, data in pairs(Codec.tar(blob)) do
            local base = name:match("([^/]+)$") or name
            local ext, mime = Codec.media(data)
            local href = "images/" .. Util.id_name(base) .. ext
            assets[#assets + 1] = {href=href, data=data, mime=mime, source=base}
            local escaped = base:gsub("([^%w])", "%%%1")
            xhtml = xhtml:gsub("https://res%.weread%.qq%.com/wrepub/" .. escaped .. "[^%s\"'<>]*", "../" .. href)
        end
    end
    state.content_format = "epub"
    return xhtml, css, assets, state
end

function Reader:_chapter_once(book, chapter, format, opt)
    opt = opt or {}
    local id = tostring(book.bookId or book.book_id)
    local uid = chapter.chapterUid or chapter.uid
    local state = self:state(id, uid)

    if format == "txt" then
        local ok, a, b, c, d = pcall(self._txt_once, self, book, chapter, opt, state)
        if ok then return a, b, c, d end
        if is_structure_chapter(chapter) and is_empty_error(a) then
            state.content_format = "structure"
            state.structural = true
            logger.info("[MiuRead][Reader] structure page generated", "chapter=", tostring(uid), "title=", tostring(chapter.title or ""))
            return structure_xhtml(chapter.title), PART_CSS, {}, state
        end
        error(a)
    end

    local ok, a, b, c, d = pcall(self._epub_once, self, book, chapter, opt, state)
    if ok then return a, b, c, d end
    local epub_error = a
    if not is_empty_error(epub_error) then error(epub_error) end

    logger.warn("[MiuRead][Reader] EPUB content empty; trying TXT fallback", "chapter=", tostring(uid), "title=", tostring(chapter.title or ""))
    local txt_ok, ta, tb, tc, td = pcall(self._txt_once, self, book, chapter, opt, state)
    if txt_ok then return ta, tb, tc, td end
    if is_structure_chapter(chapter) and not is_auth_error(ta) then
        state.content_format = "structure"
        state.structural = true
        logger.info("[MiuRead][Reader] structure page generated", "chapter=", tostring(uid), "title=", tostring(chapter.title or ""), "txt_fallback=", tostring(ta))
        return structure_xhtml(chapter.title), PART_CSS, {}, state
    end
    error(tostring(epub_error) .. "; TXT fallback: " .. tostring(ta))
end

function Reader:chapter(book, chapter, format, opt)
    local last, renewed = nil, false
    for attempt = 1, 3 do
        local ok, a, b, c, d = pcall(self._chapter_once, self, book, chapter, format, opt)
        if ok then return a, b, c, d end
        last = a
        logger.warn("[MiuRead][Reader] chapter retry", "chapter=", tostring(chapter.chapterUid or chapter.uid),
            "attempt=", tostring(attempt), "error=", tostring(a))
        if is_auth_error(a) and not renewed then
            renewed = true
            local renew_ok, renew_error = pcall(self.renew, self)
            logger.warn("[MiuRead][Reader] authentication renewal", "ok=", tostring(renew_ok), "error=", renew_ok and "" or tostring(renew_error))
        end
        if attempt < 3 then pause(attempt == 1 and 0.8 or 1.8) end
    end
    error(last or "chapter download failed")
end

function Reader:mp_articles(book_id)
    local all, offset = {}, 0
    for _ = 1, 30 do
        local data = self.http:get_json(BASE .. "/web/mp/articles?bookId=" .. Protocol.escape(book_id) .. "&offset=" .. tostring(offset), {headers={Referer=Protocol.mp_reader_url(book_id)}, retries=3})
        local groups = data.reviews or {}
        if #groups == 0 then break end
        for _, group in ipairs(groups) do
            for _, item in ipairs(group.subReviews or {}) do
                local review = item.review or item
                local mp = review.mpInfo or {}
                all[#all + 1] = {reviewId=review.reviewId, title=mp.title or "文章", cover=mp.pic_url, createTime=review.createTime}
            end
        end
        offset = offset + #groups
        if #groups < 10 then break end
    end
    return all
end

function Reader:mp_content(review_id)
    local html = self.http:download(BASE .. "/web/mp/content?reviewId=" .. Protocol.escape(review_id), {headers={Referer=BASE .. "/"}, retries=3})
    return Codec.mp_body(html)
end

local function response_header(headers, name)
    local target = tostring(name or ""):lower()
    for key, value in pairs(headers or {}) do
        if tostring(key):lower() == target then return value end
    end
end

-- Repair QR-login web cookies using the exact authenticated follow-up flow from
-- the user's working 0.3.6.7 build. This is not a login renewal and does not
-- rotate refresh tokens; it only preserves Set-Cookie values returned by
-- userInfo/apikeyGet that older MiuRead builds discarded.
function Reader:repair_login_session()
    local auth = self.store:auth()
    local jar = Util.copy(auth.cookies or {})
    local account = auth.account or {}
    local vid = tostring(jar.wr_vid or account.vid or account.user_vid or "")
    local skey = tostring(jar.wr_skey or "")
    if vid == "" or skey == "" then error("QR login credentials are incomplete") end

    local function headers()
        return {
            Accept = "application/json, text/plain, */*",
            Referer = BASE .. "/r/weread-skills",
            Cookie = Cookies.header(jar),
            ["X-Vid"] = vid,
            ["X-Skey"] = skey,
        }
    end

    local user, user_headers = self.http:get_json(
        BASE .. "/api/userInfo?userVid=" .. Protocol.escape(vid),
        {auth=false, headers=headers(), retries=1}
    )
    jar = Cookies.absorb(jar, response_header(user_headers, "set-cookie"))

    local skill, skill_headers = self.http:get_json(
        BASE .. "/api/skills/apikeyGet?only_show=1",
        {auth=false, headers=headers(), retries=1}
    )
    jar = Cookies.absorb(jar, response_header(skill_headers, "set-cookie"))

    auth.cookies = jar
    if type(skill) == "table" and tostring(skill.apikey or "") ~= "" then
        auth.api_key = tostring(skill.apikey)
    end
    auth.account = Util.merge(account, {
        name = tostring(type(user) == "table" and user.name or account.name or ""),
        vid = vid,
    })
    self.store:save_auth(auth)
    return {repaired=true, cookie_count=(function()
        local n=0; for _ in pairs(jar) do n=n+1 end; return n
    end)()}
end

function Reader:report_payload(payload, referer, retries)
    local data, _, meta = self.http:post_json(BASE .. "/web/book/read", payload,
        {headers={Origin=BASE, Referer=referer or BASE .. "/",
            Accept="application/json, text/plain, */*"}, retries=tonumber(retries) or 0})
    return data, meta
end

function Reader:report(book_id, chapter_uid, opt)
    opt = opt or {}
    local session = opt.session or self.store:session(book_id) or {}
    local payload = Protocol.read_fields{
        book_id=book_id, chapter_uid=chapter_uid, chapter_index=opt.chapter_index,
        chapter_offset=opt.offset, progress=opt.progress, elapsed=opt.elapsed,
        summary=opt.summary, psvts=optional_value(session.psvts), pclts=optional_value(session.pclts), token=optional_value(session.token),
        app_id=session.app_id, user_agent=Protocol.USER_AGENT,
    }
    return self:report_payload(payload, session.reader_url or Protocol.reader_url(book_id), 0)
end

Reader._visible_text = visible_text
Reader._is_structure_chapter = is_structure_chapter
Reader._is_empty_error = is_empty_error
Reader._is_auth_error = is_auth_error
Reader.PART_CSS = PART_CSS

return Reader
