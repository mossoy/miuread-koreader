local Config=require("miuread.config")
local Digests=require("miuread.digests")
local U=require("miuread.util")
local Updater={}; Updater.__index=Updater

function Updater:new(http,store,version,plugin_root)
    return setmetatable({http=http,store=store,version=version,plugin_root=plugin_root},self)
end

function Updater:manifest_url()
    return Config.UPDATE_MANIFEST
end

local function package_url(manifest)
    if type(manifest)~="table" then return nil end
    return manifest.package_url or manifest.url
end

function Updater:check()
    local url=self:manifest_url()
    if type(url)~="string" or not url:match("^https://") then
        return nil,"更新地址未配置"
    end
    local m=self.http:get_json(url,{auth=false,retries=2})
    if type(m)~="table" or type(m.version)~="string" or m.version=="" then
        return nil,"更新清单缺少版本号"
    end
    local pkg=package_url(m)
    if type(pkg)~="string" or not pkg:match("^https://") then
        return nil,"更新清单缺少安装包地址"
    end
    if not U.semver_newer(m.version,self.version) then
        return {current=true,version=m.version,name=m.name,notes=m.notes}
    end
    return m
end

function Updater:download(m)
    local url=package_url(m)
    if type(url)~="string" or not url:match("^https://") then error("更新包地址无效") end
    local data=self.http:download(url,{auth=false,retries=3,redirects=6,timeout={20,90}})
    if type(data)~="string" or data=="" then error("下载的更新包为空") end
    local expected=tostring(m.sha256 or ""):lower():gsub("%s+","")
    if expected=="" then error("更新清单缺少 SHA-256") end
    local actual=Digests.sha256(data):lower()
    if actual~=expected then error("更新包校验失败") end
    local p=self.store.updates_dir.."/miuread-"..U.id_name(m.version)..".zip"
    local ok,err=U.atomic_write(p,data,true); if not ok then error(err or "无法保存更新包") end
    return p
end

local function archive_entries(path)
    local cmd="unzip -Z1 "..U.shell_quote(path).." 2>/dev/null"
    local f=io.popen(cmd,"r"); if not f then return nil,"设备缺少 unzip" end
    local rows={}
    for line in f:lines() do
        line=tostring(line or "")
        if line=="" or line:sub(1,1)=="/" or line:find("\\",1,true) then
            f:close(); return nil,"更新包包含不安全路径"
        end
        for part in line:gmatch("[^/]+") do
            if part==".." then f:close(); return nil,"更新包包含不安全路径" end
        end
        rows[#rows+1]=line
    end
    f:close()
    if #rows==0 then return nil,"更新包为空" end
    return rows
end

local function safe_relative(rel)
    if type(rel)~="string" or rel=="" or rel:sub(1,1)=="/" or rel:find("\\",1,true) then return nil end
    for part in rel:gmatch("[^/]+") do if part==".." or part=="." or part=="" then return nil end end
    return rel
end

function Updater:install(path,manifest)
    local rows,err=archive_entries(path); if not rows then return nil,err end
    local prefix="miuread.koplugin/"; local found=false
    for _,x in ipairs(rows) do
        if x=="miuread.koplugin/" or x:sub(1,#prefix)==prefix then found=true
        else return nil,"更新包根目录必须是 miuread.koplugin" end
    end
    if not found then return nil,"更新包缺少插件目录" end

    local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local stage=self.store.updates_dir.."/stage-"..stamp
    local backup=self.store.updates_dir.."/backup-"..stamp
    U.remove_tree(stage); U.remove_tree(backup); U.mkdir(stage)
    local rc=os.execute("unzip -qq "..U.shell_quote(path).." -d "..U.shell_quote(stage))
    if rc~=0 and rc~=true then U.remove_tree(stage); return nil,"解压更新包失败" end
    local incoming=stage.."/miuread.koplugin"
    if not U.file_exists(incoming.."/main.lua") or not U.file_exists(incoming.."/_meta.lua") then
        U.remove_tree(stage); return nil,"更新包不是有效的 KOReader 插件"
    end

    local ok,e=U.copy_tree(self.plugin_root,backup)
    if not ok then U.remove_tree(stage); return nil,"备份当前插件失败："..tostring(e) end

    local function rollback(message)
        U.remove_tree(self.plugin_root)
        local restored,re=U.copy_tree(backup,self.plugin_root)
        U.remove_tree(stage)
        if not restored then return nil,tostring(message).."；回滚也失败："..tostring(re) end
        return nil,tostring(message).."；已恢复旧版本"
    end

    U.remove_tree(self.plugin_root)
    local moved=os.rename(incoming,self.plugin_root)
    if not moved then
        local copied,ce=U.copy_tree(incoming,self.plugin_root)
        if not copied then return rollback("安装新文件失败："..tostring(ce)) end
    end
    if not U.file_exists(self.plugin_root.."/main.lua") or not U.file_exists(self.plugin_root.."/_meta.lua") then
        return rollback("安装后的插件文件不完整")
    end

    if type(manifest.delete_list)=="table" then
        for _,rel in ipairs(manifest.delete_list) do
            rel=safe_relative(rel)
            if not rel then return rollback("delete_list 包含不安全路径") end
            local target=self.plugin_root.."/"..rel
            local removed=U.remove_tree(target)
            if removed==false then return rollback("无法删除旧文件："..rel) end
        end
    end

    U.remove_tree(stage)
    self.store:save_update_state({pending=true,expected=manifest.version,backup=backup,installed_at=os.time()})
    return true
end

function Updater:startup()
    local s=self.store:update_state()
    if not s.pending then return nil end
    if tostring(s.expected)==tostring(self.version) then
        if s.backup then U.remove_tree(s.backup) end
        self.store:save_update_state({})
        return "updated"
    end
    return "mismatch"
end

return Updater
