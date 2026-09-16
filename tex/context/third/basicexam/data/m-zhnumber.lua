if not modules then modules = { } end modules ['zhnumber'] = {
    version   = 1.0,
    comment   = "Chinese Number Conversion for ConTeXt",
    author    = "Based on zhnumber package by Qing Lee",
}

local match, gmatch, concat, tonumber, floor, abs = 
      string.match, string.gmatch, table.concat, tonumber, math.floor, math.abs

local context = context

thirddata           = thirddata or { }
local zhnumber      = thirddata.zhnumber or { }
thirddata.zhnumber  = zhnumber

zhnumber.settings = {
    zero = "〇",  -- 默认使用〇，可选"零"
}

-- 数字映射表
-- [200] = "皕" 已经删除了， 几乎没有使用案例
local digits_base = {
    normal = {
        [0] = "〇",
        [1] = "一", [2] = "二", [3] = "三", [4] = "四",
        [5] = "五", [6] = "六", [7] = "七", [8] = "八", [9] = "九",
        [10] = "十", [100] = "百", [1000] = "千", [10000] = "万", [100000000] = "亿"
    },
    cap = {
        [0] = "零",
        [1] = "壹", [2] = "贰", [3] = "叁", [4] = "肆",
        [5] = "伍", [6] = "陆", [7] = "柒", [8] = "捌", [9] = "玖",
        [10] = "拾", [100] = "佰", [1000] = "仟", [10000] = "萬", [100000000] = "亿"
    },
    all = {
        [0] = "〇",
        [1] = "一", [2] = "二", [3] = "三", [4] = "四",
        [5] = "五", [6] = "六", [7] = "七", [8] = "八", [9] = "九",
        [10] = "十", [20] = "廿", [30] = "卅", [40] = "卌",
        [100] = "百", [1000] = "千", [10000] = "万", [100000000] = "亿"
    }
}

-- 逐位读法字符映射
local digit_chars = {
    normal = { [0]="〇", [1]="一", [2]="二", [3]="三", [4]="四",
               [5]="五", [6]="六", [7]="七", [8]="八", [9]="九" },
    cap    = { [0]="零", [1]="壹", [2]="贰", [3]="叁", [4]="肆",
               [5]="伍", [6]="陆", [7]="柒", [8]="捌", [9]="玖" },
    phone  = { [0]="洞", [1]="幺", [2]="两", [3]="三", [4]="四",
               [5]="五", [6]="六", [7]="拐", [8]="八", [9]="勾" },
}

-- 天干地支
local tiangan = { "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸" }
local dizhi = { "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥" }

-- 星期
local weekdays = { "日", "一", "二", "三", "四", "五", "六" }

-- 设置零的显示方式
function zhnumber.setzero(char)
    if char ~= "零" and char ~= "〇" then
        return
    end
    zhnumber.settings.zero = char
    digits_base.normal[0] = char
    digits_base.all[0]    = char
    digit_chars.normal[0] = char
    -- cap 和 phone 的零固定为"零"和"洞"，不修改
end

-- 获取数字映射表（根据设置选择零）
local function getdigits(style)
    return digits_base[style] or digits_base.normal
end

-- 中文数字转换函数
local function tochinese(n, style)
    style = style or "normal"
    local vector = getdigits(style)
    local result, r = {}, 0
    local negative = false
    
    if n == 0 then
        return vector[0]
    end
    
    if n < 0 then
        negative = true
        n = abs(n)
    end
    
    while n > 0 do
        if n >= 100000000 then
            local m = floor(n / 100000000)
            r = r + 1; result[r] = tochinese(m, style)
            r = r + 1; result[r] = vector[100000000]
            n = n % 100000000
            if n > 0 and n < 10000000 then
                r = r + 1; result[r] = vector[0]
            end
        elseif n >= 10000 then
            local m = floor(n / 10000)
            r = r + 1; result[r] = tochinese(m, style)
            r = r + 1; result[r] = vector[10000]
            n = n % 10000
            if n > 0 and n < 1000 then
                r = r + 1; result[r] = vector[0]
            end
        elseif n >= 1000 then
            local m = floor(n / 1000)
            r = r + 1; result[r] = vector[m]
            r = r + 1; result[r] = vector[1000]
            n = n % 1000
            if n > 0 and n < 100 then
                r = r + 1; result[r] = vector[0]
            end
        elseif n >= 100 then
            local m = floor(n / 100)
            r = r + 1; result[r] = vector[m]
            r = r + 1; result[r] = vector[100]
            n = n % 100
            if n > 0 and n < 10 then
                r = r + 1; result[r] = vector[0]
            end
        elseif n >= 10 then
            local m = floor(n / 10)
            if style == "all" and m > 1 and vector[m * 10] then
                r = r + 1; result[r] = vector[m * 10]
            else
                if m > 1 then
                    r = r + 1; result[r] = vector[m]
                elseif r > 0 then
                    r = r + 1; result[r] = vector[m]
                end
                r = r + 1; result[r] = vector[10]
            end
            n = n % 10
        else
            r = r + 1; result[r] = vector[n]
            break
        end
    end
    
    -- 处理"一十"的情况
    if result[1] == vector[1] and result[2] == vector[10] then
        result[1] = ""
    end
    
    local str = concat(result)
    if negative then
        str = "负" .. str
    end
    return str
end

-- 小数转换
local function todecimal(str, style)
    style = style or "normal"
    local vector = getdigits(style)
    local result = {}
    
    for char in gmatch(str, ".") do
        local digit = tonumber(char)
        if digit then
            result[#result + 1] = vector[digit]
        end
    end
    
    return concat(result)
end

-- 分数转换
local function tofraction(num, den, style)
    style = style or "normal"
    local vector = getdigits(style)
    
    if num == 0 then
        return vector[0]
    end
    
    local result = {}
    
    -- 分母
    result[#result + 1] = tochinese(den, style)
    
    -- "分之"
    result[#result + 1] = "分之"
    
    -- 分子
    result[#result + 1] = tochinese(num, style)
    
    return concat(result)
end

-- 内部辅助函数：解析日期参数，返回 year, month, day
-- 解析失败返回 nil
-- 两个数字：第一个 > 12 视为“年/月”，否则视为“月/日”
-- 单数字：按“日”解释，年、月默认为今年本月
local function parsedate(...)
    local args = { ... }
    local nums = {}
    
    for _, v in ipairs(args) do
        for num in gmatch(tostring(v), "%d+") do
            nums[#nums + 1] = tonumber(num)
        end
    end
    
    if #nums == 0 or #nums > 3 then
        return nil
    end
    
    local year, month, day
    if #nums == 3 then
        year, month, day = nums[1], nums[2], nums[3]
    else
        local now = os.date("*t")   -- 只在需要默认值时调用
        if #nums == 2 then
            if nums[1] > 12 then
                year, month, day = nums[1], nums[2], 1
            else
                year, month, day = now.year, nums[1], nums[2]
            end
        else
            year, month, day = now.year, now.month, nums[1]
        end
    end
    
    if month < 1 or month > 12 then
        return nil
    end
    
    local mdays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    local max_day = mdays[month]
    if month == 2 then
        local is_leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
        if is_leap then
            max_day = 29
        end
    end
    if day < 1 or day > max_day then
        return nil
    end
    
    return year, month, day
end

-- 主转换函数
function zhnumber.convert(str, style)
    style = style or "normal"
    str = tostring(str or "")
    
    if str == "" then
        return ""
    end
    
    -- 统一处理负号（支持负数整数、小数、分数）
    if str:sub(1, 1) == "-" then
        return "负" .. zhnumber.convert(str:sub(2), style)
    end
    
    -- 检查是否为分数
    local num, den = match(str, "^(%d+)/(%d+)$")
    if num and den then
        return tofraction(tonumber(num), tonumber(den), style)
    end
    
    -- 检查是否为小数
    local int_part, dec_part = match(str, "^(%d*)%.(%d+)$")
    if int_part or dec_part then
        local result = {}
        if int_part and int_part ~= "" then
            result[#result + 1] = tochinese(tonumber(int_part), style)
        else
            result[#result + 1] = getdigits(style)[0]
        end
        result[#result + 1] = "点"
        result[#result + 1] = todecimal(dec_part, style)
        return concat(result)
    end
    
    -- 整数转换
    local n = tonumber(str)
    if n then
        return tochinese(n, style)
    end
    
    -- 无法转换，返回原字符串
    return str
end

-- 逐位读法：直接按字符逐位转换
function zhnumber.digits(str, style)
    style = style or "normal"
    str = tostring(str or "")
    local map = digit_chars[style] or digit_chars.normal
    local result = {}
    local negative = false

    if str:sub(1, 1) == "-" then
        negative = true
        str = str:sub(2)
    end

    for char in gmatch(str, ".") do
        local d = tonumber(char)
        if d then
            result[#result + 1] = map[d]
        else
            result[#result + 1] = char
        end
    end

    local out = concat(result)
    if negative then
        out = "负" .. out
    end
    return out
end

-- 日期转换
function zhnumber.date(...)
    local year, month, day = parsedate(...)
    if not year then
        return ""
    end
    
    local result = {}
    local vector = getdigits("normal")
    
    -- 年份（逐位转换）
    for char in gmatch(tostring(year), ".") do
        local digit = tonumber(char)
        if digit then
            result[#result + 1] = vector[digit]
        end
    end
    result[#result + 1] = "年"
    
    -- 月份
    result[#result + 1] = tochinese(month, "normal")
    result[#result + 1] = "月"
    
    -- 日期
    result[#result + 1] = tochinese(day, "normal")
    result[#result + 1] = "日"
    
    return concat(result)
end

-- 时间转换
function zhnumber.time(hour, minute)
    local h, m
    if minute ~= nil then
        h = tonumber(tostring(hour):match("%d+") or "")
        m = tonumber(tostring(minute):match("%d+") or "") or 0
    else
        local hs, ms = tostring(hour):match("^(%d+):?(%d*)$")
        h = tonumber(hs)
        m = tonumber(ms) or 0
    end
    
    if not h then
        return ""
    end
    
    local result = {}
    result[#result + 1] = tochinese(h, "normal")
    result[#result + 1] = "点"
    
    if m > 0 then
        if m < 10 then
            result[#result + 1] = zhnumber.settings.zero
        end
        result[#result + 1] = tochinese(m, "normal")
        result[#result + 1] = "分"
    end
    
    return concat(result)
end

-- 星期转换
function zhnumber.weekday(...)
    local year, month, day = parsedate(...)
    if not year then
        return ""
    end
    
    -- Zeller 公式计算星期
    local y, m, d = year, month, day
    if m < 3 then
        y = y - 1
        m = m + 12
    end
    
    local c = floor(y / 100)
    y = y % 100
    
    local w = (d + floor((m + 1) * 2.6) + y + floor(y / 4) + floor(c / 4) - 2 * c) % 7
    if w == 0 then w = 7 end
    
    return "星期" .. weekdays[w]
end

-- 天干转换
function zhnumber.tiangan(n)
    n = tonumber(n)
    if not n or n < 1 or n > 10 then
        return ""
    end
    return tiangan[n]
end

-- 地支转换
function zhnumber.dizhi(n)
    n = tonumber(n)
    if not n or n < 1 or n > 12 then
        return ""
    end
    return dizhi[n]
end

-- 干支转换
function zhnumber.ganzhi(n)
    n = tonumber(n)
    if not n or n < 1 or n > 60 then
        return ""
    end
    
    local tg_index = (n - 1) % 10 + 1
    local dz_index = (n - 1) % 12 + 1
    
    return tiangan[tg_index] .. dizhi[dz_index]
end

-- 年份干支
function zhnumber.ganzhinian(year)
    year = tonumber(year)
    if not year then
        return ""
    end
    
    -- 公元4年为甲子年
    local offset = (year - 4) % 60
    if offset < 0 then
        offset = offset + 60
    end
    
    return zhnumber.ganzhi(offset + 1)
end

-- 注册ConTeXt命令
interfaces.implement {
    name = "zhnumber",
    actions = { zhnumber.convert, context },
    arguments = { "string", "string" }
}

interfaces.implement {
    name = "zhdigits",
    actions = { zhnumber.digits, context },
    arguments = { "string", "string" }
}

interfaces.implement {
    name = "zhdate",
    actions = { zhnumber.date, context },
    arguments = { "string" }
}

interfaces.implement {
    name = "zhsetzero",
    actions = zhnumber.setzero,
    arguments = { "string" }
}

interfaces.implement {
    name = "zhtime",
    actions = { zhnumber.time, context },
    arguments = { "string" }
}

interfaces.implement {
    name = "zhweekday",
    actions = { zhnumber.weekday, context },
    arguments = { "string" }
}

interfaces.implement {
    name = "zhtiangan",
    actions = { zhnumber.tiangan, context },
    arguments = { "integer" }
}

interfaces.implement {
    name = "zhdizhi",
    actions = { zhnumber.dizhi, context },
    arguments = { "integer" }
}

interfaces.implement {
    name = "zhganzhi",
    actions = { zhnumber.ganzhi, context },
    arguments = { "integer" }
}

interfaces.implement {
    name = "zhganzhinian",
    actions = { zhnumber.ganzhinian, context },
    arguments = { "integer" }
}

-- ============================================================
-- 新增：供 \defineconversion 使用的单参数接口
-- ============================================================

-- zhnumber.convert 的多种风格
interfaces.implement {
    name    = "zhnumber_normal",
    actions = function(s) context(zhnumber.convert(s, "normal")) end,
    arguments = "string",
}
interfaces.implement {
    name    = "zhnumber_cap",
    actions = function(s) context(zhnumber.convert(s, "cap")) end,
    arguments = "string",
}
interfaces.implement {
    name    = "zhnumber_all",
    actions = function(s) context(zhnumber.convert(s, "all")) end,
    arguments = "string",
}

-- zhnumber.digits 的多种风格（逐位读法）
interfaces.implement {
    name    = "zhdigits_normal",
    actions = function(s) context(zhnumber.digits(s, "normal")) end,
    arguments = "string",
}
interfaces.implement {
    name    = "zhdigits_cap",
    actions = function(s) context(zhnumber.digits(s, "cap")) end,
    arguments = "string",
}
interfaces.implement {
    name    = "zhdigits_phone",
    actions = function(s) context(zhnumber.digits(s, "phone")) end,
    arguments = "string",
}
