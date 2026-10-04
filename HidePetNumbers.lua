-- ============================================================================
--  AI 宠物血条百分比 —— 让（猎人）宠物头像的血条只显示生命值百分比，
--  同时隐藏能量数字与宠物受到的伤害/治疗数字（启动即自动生效）
--  适用版本：魔兽世界 12.1（Interface 120100，Midnight 及之后）
--
--  用到的暴雪最新接口：
--   * UnitHealthPercent(unit[, usePredicted[, curve]])
--       直接返回生命值百分比。注意：12.0 起不带 curve 时返回的是「归一化」的
--       0~1 小数，必须配合 CurveConstants.ScaleTo100 曲线才能拿到 0~100。
--   * C_CurveUtil.CreateCurve() / Enum.LuaCurveType.Linear
--       把「乘 100」这个运算放进暴雪的受保护环境里做。12.0 起战斗中血量是
--       「密值(Secret Value)」，在 Lua 里对它做乘除法会直接报错。
--   * FontString:SetText + string.format
--       这是暴雪官方允许的「密值显示」通路：允许对密值调用 string.format，
--       也允许把密值字符串传给 SetText（插件只能显示、不能读取）。
--   * issecretvalue()   —— 检测密值，用于降级/兜底判断。
--   * RegisterUnitEvent —— 按单位订阅 UNIT_HEALTH / UNIT_MAXHEALTH。
--
--  命令：/petpct            开关百分比显示
--        /petpct mana       开关宠物能量(集中值/法力)数字
--        /petpct hit        开关宠物受到的伤害/治疗数字
--        /petpct size 12    设置百分比字号（0 = 跟随暴雪默认）
--        /petpct reset      恢复默认设置
-- ============================================================================

local ADDON_NAME = "HidePetNumbers"
local DB_NAME    = "HidePetNumbersDB"

local DEFAULTS = {
    showPercent      = true,   -- 显示宠物生命值百分比
    hidePower        = true,   -- 隐藏宠物能量数字
    hideHitIndicator = true,   -- 隐藏宠物受到的伤害/治疗数字（PetHitIndicator）
    fontSize         = 0,      -- 0 = 跟随暴雪默认字号
}

-- 暴雪原生的宠物血条 / 能量条文字对象
-- 状态文字设置为「数值」或「百分比」时用的是 PetFrameHealthBarText；
-- 设置为「同时显示」时用的是 Left(百分比) + Right(数值) 两个。两种都要处理。
local HEALTH_TEXTS = {
    "PetFrameHealthBarText",
    "PetFrameHealthBarTextLeft",
    "PetFrameHealthBarTextRight",
}
local POWER_TEXTS = {
    "PetFrameManaBarText",
    "PetFrameManaBarTextLeft",
    "PetFrameManaBarTextRight",
}

local DB
local percentText
local built = false

---------------------------------------------------------------------------
-- 密值（Secret Value）安全工具
---------------------------------------------------------------------------
local function IsSecret(v)
    if type(issecretvalue) == "function" then
        return issecretvalue(v) and true or false
    end
    return false
end

-- 密值不能参与 if / and / or 等条件判断，遇到密值时返回 fallback
local function SafeBool(v, fallback)
    if IsSecret(v) then return fallback end
    return v and true or false
end

---------------------------------------------------------------------------
-- 0~1 → 0~100 的曲线（暴雪在受保护环境内帮我们做乘法）
---------------------------------------------------------------------------
local scaleCurve          -- nil = 还没初始化；false = 确定拿不到

local function GetScaleCurve()
    if scaleCurve ~= nil then return scaleCurve end
    scaleCurve = false

    -- 优先直接用暴雪提供的常量曲线
    if type(CurveConstants) == "table" and CurveConstants.ScaleTo100 then
        scaleCurve = CurveConstants.ScaleTo100
    elseif type(C_CurveUtil) == "table" and C_CurveUtil.CreateCurve then
        -- CurveConstants.ScaleTo100 等价于下面这段
        local c = C_CurveUtil.CreateCurve()
        if c then
            c:SetType(Enum.LuaCurveType.Linear)
            c:AddPoint(0.0, 0)
            c:AddPoint(1.0, 100)
            scaleCurve = c
        end
    end

    return scaleCurve
end

---------------------------------------------------------------------------
-- 取宠物生命值百分比（0~100）
---------------------------------------------------------------------------
local function GetPetHealthPercent()
    if UnitHealthPercent then
        local curve = GetScaleCurve()
        if curve then
            -- 第 2 个参数 usePredicted = true：用战斗信息预测，数值更实时
            return UnitHealthPercent("pet", true, curve)
        end
    end

    -- 兜底：老版本 / 拿不到曲线时才自己算
    local cur, maxH = UnitHealth("pet"), UnitHealthMax("pet")
    if IsSecret(cur) or IsSecret(maxH) then return nil end  -- 密值不能做除法
    if not maxH or maxH == 0 then return nil end
    return cur / maxH * 100
end

---------------------------------------------------------------------------
-- 屏蔽 / 恢复暴雪原生文字
-- 12.x 里 TextStatusBar 的更新有一部分在 C 侧执行，可能绕过 Lua 层的 Show
-- 覆盖，所以「覆盖 Show/SetShown + OnShow 脚本 + 透明」三管齐下。
---------------------------------------------------------------------------
-- 单个对象的屏蔽 / 恢复
local function KillRegion(region, enable)
    if not region then return end

    if enable then
        if not region.__petPctSaved then
            region.__petPctSaved = { Show = region.Show, SetShown = region.SetShown }
            region.Show = function() end
            region.SetShown = function() end
            pcall(region.SetScript, region, "OnShow", function(self) self:Hide() end)
        end
        region:Hide()
        region:SetAlpha(0)
    elseif region.__petPctSaved then
        region.Show = region.__petPctSaved.Show
        region.SetShown = region.__petPctSaved.SetShown
        region.__petPctSaved = nil
        pcall(region.SetScript, region, "OnShow", nil)
        region:SetAlpha(1)
        region:Show()
    end
end

local function KillTexts(names, enable)
    for i = 1, #names do
        local fs = _G[names[i]]
        if fs and fs:IsObjectType("FontString") then
            KillRegion(fs, enable)
        end
    end
end

-- 宠物受到的伤害 / 治疗数字（原生命令：/run PetHitIndicator:Hide() PetHitIndicator.Show = function() end）
local function KillHitIndicator(enable)
    KillRegion(_G.PetHitIndicator, enable)
end

---------------------------------------------------------------------------
-- 创建我们自己的百分比文字
---------------------------------------------------------------------------
local function ApplyFont()
    if not percentText then return end
    local src = _G.PetFrameHealthBarText or _G.PetFrameHealthBarTextLeft or _G.PetFrameHealthBarTextRight
    local font, size, flags
    if src then
        font, size, flags = src:GetFont()
    end
    if not font then
        font, size, flags = "Fonts\\ARIALN.TTF", 10, "OUTLINE"
    end
    percentText:SetFont(font, (DB.fontSize and DB.fontSize > 0) and DB.fontSize or (size or 10), flags)
end

local function Build()
    local bar = _G.PetFrameHealthBar
    if not bar then return false end

    if not percentText then
        percentText = bar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
        percentText:SetPoint("CENTER", bar, "CENTER", 0, 0)
        percentText:SetShadowOffset(1, -1)
        percentText:SetShadowColor(0, 0, 0, 1)
    end

    ApplyFont()
    built = true
    return true
end

---------------------------------------------------------------------------
-- 刷新
---------------------------------------------------------------------------
local function Update()
    if not DB then InitDB() end

    -- 伤害/治疗数字：这个不依赖血条框体，先执行，保证一进游戏就生效
    KillHitIndicator(DB.hideHitIndicator)

    if not built and not Build() then return end

    KillTexts(POWER_TEXTS, DB.hidePower)

    if not DB.showPercent then
        KillTexts(HEALTH_TEXTS, false)   -- 还回暴雪自己的显示
        percentText:Hide()
        return
    end

    KillTexts(HEALTH_TEXTS, true)        -- 挡掉暴雪的血量数字

    -- 没有宠物、或宠物已阵亡时不显示
    if not SafeBool(UnitExists("pet"), true) then
        percentText:Hide()
        return
    end
    if SafeBool(UnitIsDead("pet"), false) or SafeBool(UnitIsGhost("pet"), false) then
        percentText:Hide()
        return
    end

    local pct = GetPetHealthPercent()
    if pct == nil then
        percentText:Hide()
        return
    end

    -- string.format / SetText 都接受密值，插件只是「显示」，不会读到明文
    percentText:SetText(format("%.0f%%", pct))
    percentText:Show()
end

---------------------------------------------------------------------------
-- 存档
---------------------------------------------------------------------------
local function InitDB()
    if type(_G[DB_NAME]) ~= "table" then
        _G[DB_NAME] = {}
    end
    DB = _G[DB_NAME]
    for k, v in pairs(DEFAULTS) do
        if DB[k] == nil then DB[k] = v end
    end
end

---------------------------------------------------------------------------
-- 事件
---------------------------------------------------------------------------
local Frame = CreateFrame("Frame")
Frame:RegisterEvent("ADDON_LOADED")
Frame:RegisterEvent("PLAYER_LOGIN")
Frame:RegisterEvent("PLAYER_ENTERING_WORLD")
Frame:RegisterEvent("UNIT_PET")
Frame:RegisterEvent("CVAR_UPDATE")
Frame:RegisterUnitEvent("UNIT_HEALTH", "pet")
Frame:RegisterUnitEvent("UNIT_MAXHEALTH", "pet")

Frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if (...) == ADDON_NAME then
            InitDB()
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        Build()
        Update()
        -- 晚一点再刷一次，防止宠物框体此时还没完全就绪
        C_Timer.After(1, function()
            Build()
            Update()
        end)
        return
    end

    if event == "UNIT_PET" then
        -- 换宠物 / 召唤 / 解散，稍延迟等框体重建完成
        C_Timer.After(0.2, Update)
        return
    end

    Update()
end)

---------------------------------------------------------------------------
-- 斜杠命令
---------------------------------------------------------------------------
local function Chat(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffABD473[宠物血条百分比]|r " .. msg)
end

SLASH_AIPETPERCENT1 = "/petpct"
SLASH_AIPETPERCENT2 = "/petpercent"

SlashCmdList["AIPETPERCENT"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "" then
        DB.showPercent = not DB.showPercent
        Chat("宠物生命值百分比：" .. (DB.showPercent and "开启" or "关闭"))

    elseif msg == "mana" or msg == "power" then
        DB.hidePower = not DB.hidePower
        Chat("隐藏宠物能量数字：" .. (DB.hidePower and "开启" or "关闭"))

    elseif msg == "hit" or msg == "dmg" then
        DB.hideHitIndicator = not DB.hideHitIndicator
        Chat("隐藏宠物受到的伤害/治疗数字：" .. (DB.hideHitIndicator and "开启" or "关闭"))

    elseif msg == "reset" then
        DB.showPercent     = DEFAULTS.showPercent
        DB.hidePower       = DEFAULTS.hidePower
        DB.hideHitIndicator = DEFAULTS.hideHitIndicator
        DB.fontSize        = DEFAULTS.fontSize
        ApplyFont()
        Chat("已恢复默认设置")

    else
        local n = tonumber(msg:match("^size%s+(%d+)$"))
        if n then
            DB.fontSize = n
            ApplyFont()
            Chat("百分比字号：" .. n)
        else
            Chat("用法：/petpct | /petpct mana | /petpct hit | /petpct size 12 | /petpct reset")
            return
        end
    end

    Update()
end
