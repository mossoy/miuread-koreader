local Util = require("miuread.util")
local Cookies = {}
local reserved = {path=true,domain=true,expires=true,["max-age"]=true,samesite=true,secure=true,httponly=true}
local function segments(line)
    local out = {}
    for part in tostring(line or ""):gmatch("[^;]+") do table.insert(out, Util.trim(part)) end
    return out
end
function Cookies.parse_header(text)
    local jar = {}
    for _, part in ipairs(segments(text)) do
        local k, v = part:match("^([^=]+)=(.*)$")
        if k then
            local name=Util.trim(k)
            if not reserved[name:lower()] then jar[name]=Util.trim(v) end
        end
    end
    return jar
end
function Cookies.header(jar)
    local keys, out = {}, {}
    for k, v in pairs(jar or {}) do if type(k) == "string" and v ~= nil and tostring(v) ~= "" then table.insert(keys, k) end end
    table.sort(keys)
    for _, k in ipairs(keys) do table.insert(out, k .. "=" .. tostring(jar[k])) end
    return table.concat(out, "; ")
end
local function split_set_cookie(raw)
    if type(raw) == "table" then return raw end
    local text = tostring(raw or "")
    local out, start, in_expires = {}, 1, false
    for i = 1, #text do
        local tail = text:sub(i):lower()
        if tail:sub(1,8) == "expires=" then in_expires = true end
        local ch = text:sub(i,i)
        if in_expires and ch == ";" then in_expires = false end
        if ch == "," and not in_expires then
            local nextpart = text:sub(i+1):match("^%s*([^=;,]+)=")
            if nextpart then table.insert(out, Util.trim(text:sub(start, i-1))); start = i+1 end
        end
    end
    if start <= #text then table.insert(out, Util.trim(text:sub(start))) end
    return out
end
function Cookies.absorb(jar, raw)
    jar = jar or {}
    for _, line in ipairs(split_set_cookie(raw)) do
        local first = line:match("^([^;]+)") or ""
        local k, v = first:match("^%s*([^=]+)=(.*)$")
        if k then
            k, v = Util.trim(k), Util.trim(v)
            local lower = line:lower()
            if v == "" or lower:find("max%-age=0") then jar[k] = nil else jar[k] = v end
        end
    end
    return jar
end
return Cookies
