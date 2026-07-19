local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local LuaSettings=require("luasettings")
local Config=require("miuread.config")
local U=require("miuread.util")
local Store={}; Store.__index=Store
local defaults={
 schema=Config.SCHEMA,
 auth={api_key="",cookies={},account={name="",vid="",logged_at=0}},
 preferences={images=true,mp_images=false,shelf_covers=true,download_keep_awake=true,show_annotations=true,annotation_mode="all",low_resource=false,download_dir="",shelf_sort="update",shelf_filters={},thoughts={font="standard",width_ratio=0.74,height_ratio=0.64},update={manifest=Config.UPDATE_MANIFEST},sync={time_enabled=false,progress_enabled=true,manual_only=false,auto_upload=false,pull_on_open=true,check_resume=false,require_verified=false,interval=Config.READ_INTERVAL,idle_timeout=Config.IDLE_TIMEOUT,threshold=Config.REMOTE_THRESHOLD,resume_after=300}},
 library={},sessions={},shelf_cache={books={},mp={},updated_at=0},cover_index={},update_state={},
}
local function public_documents_root(data_dir)
    local kindle_documents = "/mnt/us/documents"
    if lfs.attributes(kindle_documents,"mode")=="directory" then
        return kindle_documents .. "/MiuRead"
    end
    local ok, home = pcall(function() return DataStorage:getDataDir() end)
    if ok and type(home)=="string" and home~="" then
        return home .. "/MiuRead"
    end
    return data_dir .. "/books"
end

function Store:new()
    local data=DataStorage:getFullDataDir().."/"..Config.DATA_DIR; U.mkdir(data); U.mkdir(data.."/books"); U.mkdir(data.."/covers"); U.mkdir(data.."/temp"); U.mkdir(data.."/updates")
    local o=setmetatable({data_dir=data,cache_books_dir=data.."/books",default_books_dir=public_documents_root(data),covers_dir=data.."/covers",temp_dir=data.."/temp",updates_dir=data.."/updates",settings_path=DataStorage:getSettingsDir().."/miuread.lua"},self)
    o.db=LuaSettings:open(o.settings_path); for k,v in pairs(defaults) do if o.db:readSetting(k,nil)==nil then o.db:saveSetting(k,U.copy(v)) end end; o:migrate(); o:migrate_legacy_epubs(); o.db:flush(); return o
end
function Store:migrate()
    local schema=tonumber(self.db:readSetting("schema",1)) or 1
    if schema<Config.SCHEMA then
        local previous=self.db:readSetting("preferences",{}) or {}
        local p=U.merge(defaults.preferences,previous)
        if schema<10 then
            p.annotation_mode="all"
            p.show_annotations=true
            p.sync=p.sync or {}
            p.sync.manual_only=true
            p.sync.auto_upload=false
            p.sync.pull_on_open=false
            p.sync.check_resume=false
            p.sync.require_verified=false
        end
        if schema<11 and previous.download_keep_awake==nil then
            p.download_keep_awake=true
        end
        -- Schema 12 keeps private checkpoints/comments in koreader/miuread while
        -- final EPUB files default to the normal KOReader documents directory.
        if schema<13 then
            local sessions=self.db:readSetting("sessions",{}) or {}
            for _,session in pairs(sessions) do
                if type(session)=="table" then
                    session.report_context=nil
                    session.psvts=nil; session.pclts=nil; session.token=nil
                    session.reader_url=nil; session.context_updated_at=nil
                    session.last_path=nil; session.last_attempts=nil; session.last_stage=nil
                    session.last_response_summary=nil; session.last_http_code=nil
                    session.last_http_length=nil; session.last_payload_public=nil
                    session.last_error=nil; session.consecutive_failures=0
                    session.read_context_version=2
                end
            end
            self.db:saveSetting("sessions",sessions)
        end
        if schema<15 then
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.progress_enabled==nil then p.sync.progress_enabled=true end
            p.sync.pull_on_open=p.sync.progress_enabled~=false
            p.sync.require_verified=false
            p.sync.manual_only=false
        end
        if schema<16 then
            -- Public builds use one fixed OTA manifest. Legacy channel/URL
            -- preferences are ignored and replaced by the repository address.
            p.update={manifest=Config.UPDATE_MANIFEST}
        end
        self.db:saveSetting("preferences",p)
        self.db:saveSetting("schema",Config.SCHEMA)
    end
end
function Store:get(k,d) local v=self.db:readSetting(k,nil); return v==nil and U.copy(d) or v end
function Store:set(k,v) self.db:saveSetting(k,v); self.db:flush() end
function Store:auth() return U.merge(defaults.auth,self:get("auth",{})) end
function Store:save_auth(v) self:set("auth",U.merge(defaults.auth,v or {})) end
function Store:clear_auth() self:set("auth",U.copy(defaults.auth)) end
function Store:preferences() return U.merge(defaults.preferences,self:get("preferences",{})) end
function Store:save_preferences(v) self:set("preferences",U.merge(defaults.preferences,v or {})) end
function Store:books_root() local p=self:preferences().download_dir; if p=="" then p=self.default_books_dir end; U.mkdir(p); return p end
function Store:epub_root() return self:books_root() end
function Store:book_dir(id) local p=self.cache_books_dir.."/"..U.id_name(id); U.mkdir(p); return p end
function Store:epub_path(filename) local p=self:epub_root().."/"..tostring(filename); U.mkdir(self:epub_root()); return p end

local function basename(path) return tostring(path or ""):match("([^/]+)$") end
function Store:migrate_legacy_epubs()
    local all=self.db:readSetting("library",{}) or {}
    local changed=false
    local root=self:epub_root()
    local function move_record(record)
        if type(record)~="table" or type(record.file)~="string" or record.file=="" then return end
        if not U.file_exists(record.file) then return end
        if record.file:sub(1,#root+1)==root.."/" then return end
        if record.file:sub(1,#self.cache_books_dir+1)~=self.cache_books_dir.."/" then return end
        local name=basename(record.file); if not name then return end
        local target=root.."/"..name
        if U.file_exists(target) then
            local stem,ext=name:match("^(.*)(%.epub)$")
            target=root.."/"..tostring(stem or name).." [迁移]"..tostring(ext or "")
        end
        local ok=os.rename(record.file,target)
        if not ok then ok=U.copy_file(record.file,target); if ok then os.remove(record.file) end end
        if ok then record.file=target; record.directory=root; changed=true end
    end
    for _,book in pairs(all) do
        for _,record in pairs(book.variants or {}) do move_record(record) end
        for _,row in pairs(book.chapters or {}) do for _,record in pairs(row or {}) do move_record(record) end end
        if changed then book.directory=root end
    end
    if changed then self.db:saveSetting("library",all) end
end
function Store:library() return self:get("library",{}) end
function Store:book(id) return self:library()[tostring(id)] end
function Store:save_book(id,patch)
    local all=self:library(); local key=tostring(id); all[key]=U.merge(all[key] or {book_id=key,variants={},chapters={}},patch or {}); self:set("library",all); return all[key]
end
function Store:save_variant(id,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.variants=b.variants or {}; b.variants[kind]=U.copy(record); return self:save_book(id,b)
end
function Store:save_chapter_variant(id,uid,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.chapters=b.chapters or {}; local key=tostring(uid); b.chapters[key]=b.chapters[key] or {}; b.chapters[key][kind]=U.copy(record); return self:save_book(id,b)
end
function Store:variant(id,kind) local b=self:book(id); return b and b.variants and b.variants[kind] end
function Store:chapter_variant(id,uid,kind) local b=self:book(id); return b and b.chapters and b.chapters[tostring(uid)] and b.chapters[tostring(uid)][kind] end
function Store:delete_variant(id,kind)
    local all=self:library(); local b=all[tostring(id)]; if not b then return end; local r=b.variants and b.variants[kind]; if r and r.file then os.remove(r.file) end; if b.variants then b.variants[kind]=nil end; self:set("library",all)
end
function Store:delete_chapter(id,uid,kind)
    local all=self:library(); local b=all[tostring(id)]; local row=b and b.chapters and b.chapters[tostring(uid)]; local r=row and row[kind]; if r and r.file then os.remove(r.file) end; if row then row[kind]=nil; if next(row)==nil then b.chapters[tostring(uid)]=nil end end; self:set("library",all)
end
function Store:delete_book(id)
    local all=self:library(); local b=all[tostring(id)]; if b then
        for _,r in pairs(b.variants or {}) do if r.file then os.remove(r.file) end end
        for _,row in pairs(b.chapters or {}) do for _,r in pairs(row) do if r.file then os.remove(r.file) end end end
        -- Final EPUBs are removed above; only this book's private cache tree is
        -- deleted. Never remove the shared /documents/MiuRead directory.
        U.remove_tree(self:book_dir(id))
    end; all[tostring(id)]=nil; self:set("library",all)
end
function Store:all_books()
    local o={}; for id,b in pairs(self:library()) do local x=U.copy(b); x.book_id=x.book_id or id; o[#o+1]=x end
    table.sort(o,function(a,b) return tonumber(a.updated_at or a.downloaded_at or 0)>tonumber(b.updated_at or b.downloaded_at or 0) end); return o
end
function Store:file_record(path)
    if not path then return nil end
    for _,b in ipairs(self:all_books()) do
        for kind,r in pairs(b.variants or {}) do if r.file==path then return b,r,kind end end
        for uid,row in pairs(b.chapters or {}) do for kind,r in pairs(row) do if r.file==path then r.chapter_uid=uid; return b,r,kind end end end
    end
end
function Store:session(id) return self:get("sessions",{})[tostring(id)] end
function Store:save_session(id,patch) local a=self:get("sessions",{}); local k=tostring(id); a[k]=U.merge(a[k] or {},patch or {}); self:set("sessions",a); return a[k] end
function Store:clear_session(id) local a=self:get("sessions",{}); a[tostring(id)]=nil; self:set("sessions",a) end
function Store:shelf_cache() return U.merge(defaults.shelf_cache,self:get("shelf_cache",{})) end
function Store:save_shelf_cache(v) self:set("shelf_cache",U.merge(defaults.shelf_cache,v or {})) end
function Store:cover_path(id) return self.covers_dir.."/"..U.id_name(id)..".img" end
function Store:update_state() return self:get("update_state",{}) end
function Store:save_update_state(v) self:set("update_state",v or {}) end
function Store:flush() self.db:flush() end
function Store:reload()
    self.db = LuaSettings:open(self.settings_path)
    return self
end
return Store
