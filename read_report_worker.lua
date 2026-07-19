-- Exact reading-context subset copied from the working 0.3.6.7 Content module.
local WeRead = require("miuread.legacy.weread")
local Content = {}

function Content.extract_reader_state(html)
    return {
        book_id = html:match([["bookId"%s*:%s*"([^"]+)"]]) or html:match([["bookId"%s*:%s*(%d+)]]),
        title = html:match([["title"%s*:%s*"([^"]+)"]]),
        author = html:match([["author"%s*:%s*"([^"]+)"]]),
        psvts = html:match([["psvts"%s*:%s*"([^"]+)"]]),
        pclts = html:match([["pclts"%s*:%s*"([^"]+)"]]),
        token = html:match([["token"%s*:%s*"([^"]+)"]]),
    }
end

function Content.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then records = payload.data end
    if type(records) ~= "table" then return {} end
    if records.bookId or records.updated then records = { records } end
    for _, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            return record.updated or record.chapterInfos or record.chapters or {}
        end
    end
    return {}
end

function Content.first_readable_chapter(chapters)
    for _, chapter in ipairs(chapters or {}) do
        if tonumber(chapter.wordCount or 0) > 0 and tostring(chapter.title or "") ~= "封面" then
            return chapter
        end
    end
end

function Content.readable_chapters(chapters)
    local out = {}
    for _, chapter in ipairs(chapters or {}) do
        if tonumber(chapter.wordCount or 0) > 0 and tostring(chapter.title or "") ~= "封面" then
            out[#out + 1] = chapter
        end
    end
    return out
end

function Content.ensure_reader_state(client, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or WeRead.reader_url(book_id)
    local reader_html = client:get_text(reader_url, { referer = reader_url })
    local state = Content.extract_reader_state(reader_html)
    book.book_id = book.book_id or state.book_id or book.bookId
    book.title = book.title or state.title
    book.author = book.author or state.author
    book.psvts = state.psvts or book.psvts
    book.pclts = state.pclts or book.pclts
    book.token = state.token or book.token
    book.reader_url = reader_url
    if not book.psvts then error("reader.psvts not found") end
    return state
end

function Content.fetch_catalog(client, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or WeRead.reader_url(book_id)
    local catalog = client:post_json("https://weread.qq.com/web/book/chapterInfos", {
        bookIds = { tostring(book_id) },
    }, { referer = reader_url })
    local chapters = Content.readable_chapters(Content.normalize_chapters(catalog, book_id))
    book.chapters = chapters
    return chapters
end

return Content
