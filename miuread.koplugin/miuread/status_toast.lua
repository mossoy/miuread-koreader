local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local Toast = InputContainer:extend{
    title = "",
    text = "",
    timeout = 3,
    modal = false,
    _timeout_func = nil,
    on_close_callback = nil,
}

local function repaint(widget, dimen)
    if not dimen then return end
    UIManager:setDirty(widget, function()
        return "partial", dimen
    end)
end

local function one_line(title, text)
    local left = tostring(title or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local right = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if left == "" then return right end
    if right == "" then return left end
    return left .. " · " .. right
end

function Toast:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local side_margin = math.max(Screen:scaleBySize(12), math.floor(screen_w * 0.018))
    local bottom_margin = math.max(Screen:scaleBySize(24), math.floor(screen_h * 0.030))
    local padding_h = math.max(Screen:scaleBySize(10), tonumber(Size.padding.default) or 0)
    local padding_v = math.max(Screen:scaleBySize(6), tonumber(Size.padding.small) or 0)
    local border = math.max(1, tonumber(Size.border.window) or 1)

    local label = TextWidget:new{
        text = one_line(self.title, self.text),
        face = Font:getFace("x_smallinfofont"),
        padding = 0,
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = tonumber(Size.radius.window) or 0,
        bordersize = border,
        margin = 0,
        padding = math.max(padding_h, padding_v),
        label,
    }

    local frame_size = self.frame:getSize()
    local x = math.max(side_margin, math.floor((screen_w - frame_size.w) / 2))
    local y = math.max(side_margin, screen_h - frame_size.h - bottom_margin)
    self.popup_dimen = Geom:new{x = x, y = y, w = frame_size.w, h = frame_size.h}
    self.frame.overlap_offset = {x, y}
    self[1] = OverlapGroup:new{
        dimen = Screen:getSize(),
        allow_mirroring = false,
        self.frame,
    }
end

function Toast:onShow()
    repaint(self, self.popup_dimen)
    local timeout = tonumber(self.timeout)
    if timeout and timeout > 0 then
        self._timeout_func = function()
            self._timeout_func = nil
            UIManager:close(self)
        end
        UIManager:scheduleIn(timeout, self._timeout_func)
    end
    return true
end

function Toast:onCloseWidget()
    local old_dimen = self.popup_dimen and self.popup_dimen:copy() or nil
    if self._timeout_func then
        UIManager:unschedule(self._timeout_func)
        self._timeout_func = nil
    end
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback)
    end
    repaint(nil, old_dimen)
end

local M = {}
local active_toast = nil

function M.show(opts)
    opts = opts or {}
    if active_toast then
        pcall(UIManager.close, UIManager, active_toast)
        active_toast = nil
    end

    local toast
    toast = Toast:new{
        title = opts.title,
        text = opts.text,
        timeout = opts.timeout or 3,
        on_close_callback = function()
            if active_toast == toast then active_toast = nil end
        end,
    }
    active_toast = toast
    UIManager:show(toast)
    return toast
end

return M
