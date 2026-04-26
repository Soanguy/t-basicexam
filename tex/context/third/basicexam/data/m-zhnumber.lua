if not modules then modules = { } end modules ['zhnumber'] = {
    version   = 1.0,
    comment   = "Chinese Number Conversion for ConTeXt",
    author    = "Based on zhnumber package by Qing Lee",
}

local format, match, gmatch, concat, tonumber, floor, ceil, abs = 
      string.format, string.match, string.gmatch, table.concat, tonumber, math.floor, math.ceil, math.abs

local context = context

thirddata           = thirddata or { }
local zhnumber      = thirddata.zhnumber or { }
thirddata.zhnumber  = zhnumber

zhnumber.settings = {
    zero = "〇",  -- 默认使用〇，可选"零"
}

-- 设置零的显示方式
function zhnumber.setzero(char)
    if char == "零" or char == "〇" then
        zhnumber.settings.zero = char
    end
end

-- 数字映射表
local digits_base = {
    normal = {
        [1] = "一", [2] = "二", [3] = "三", [4] = "四",
        [5] = "五", [6] = "六", [7] = "七", [8] = "八", [9] = "九",
        [10] = "十", [100] = "百", [1000] = "千", [10000] = "万", [100000000] = "亿"
    },
    cap = {
        [1] = "壹", [2] = "贰", [3] = "叁", [4] = "肆",
        [5] = "伍", [6] = "陆", [7] = "柒", [8] = "捌", [9] = "玖",
        [10] = "拾", [100] = "佰", [1000] = "仟", [10000] = "萬", [100000000] = "亿"
    },
    all = {
        [1] = "一", [2] = "二", [3] = "三", [4] = "四",
        [5] = "五", [6] = "六", [7] = "七", [8] = "八", [9] = "九",
        [10] = "十", [20] = "廿", [30] = "卅", [40] = "卌",
        [100] = "百", [200] = "皕", [1000] = "千", [10000] = "万", [100000000] = "亿"
    }
}

-- 获取数字映射表（根据设置选择零）
local function getdigits(style)
    local base = digits_base[style] or digits_base.normal
    local result = {}
    for k, v in pairs(base) do
        result[k] = v
    end
    result[0] = zhnumber.settings.zero
    return result
end

-- 天干地支
local tiangan = { "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸" }
local dizhi = { "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥" }

-- 星期
local weekdays = { "日", "一", "二", "三", "四", "五", "六" }

-- 中文数字转换函数
local function tochinese(n, style)
    style = style or "normal"
    local vector = getdigits(style)
    local result, r = {}, 0
    
    if n == 0 then
        return vector[0]
    end
    
    -- 处理负数
    if n < 0 then
        r = r + 1
        result[r] = "负"
        n = abs(n)
    end
    
    -- 转换整数部分
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
            if style == "all" and vector[m * 10] then
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
    
    return concat(result)
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

-- 主转换函数
function zhnumber.convert(str, style)
    style = style or "normal"
    
    -- 检查是否为空
    if not str or str == "" then
        return ""
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
        
        -- 整数部分
        if int_part and int_part ~= "" then
            result[#result + 1] = tochinese(tonumber(int_part), style)
        else
            result[#result + 1] = getdigits(style)[0]
        end
        
        -- 小数点
        result[#result + 1] = "点"
        
        -- 小数部分
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

-- 日期转换
function zhnumber.date(year, month, day)
    -- 支持单字符串参数或三个参数
    if not month and not day then
        local str = year
        year, month, day = match(str, "^(%d+)/(%d+)/(%d+)$")
    end
    
    if not year or not month or not day then
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
    result[#result + 1] = tochinese(tonumber(month), "normal")
    result[#result + 1] = "月"
    
    -- 日期
    result[#result + 1] = tochinese(tonumber(day), "normal")
    result[#result + 1] = "日"
    
    return concat(result)
end

-- 时间转换
function zhnumber.time(hour, minute)
    -- 支持单字符串参数或两个参数
    if not minute then
        local str = hour
        hour, minute = match(str, "^(%d+):(%d+)$")
    end
    
    if not hour then
        return ""
    end
    
    local result = {}
    
    -- 小时
    result[#result + 1] = tochinese(tonumber(hour), "normal")
    result[#result + 1] = "点"
    
    -- 分钟
    if minute and tonumber(minute) > 0 then
        result[#result + 1] = tochinese(tonumber(minute), "normal")
        result[#result + 1] = "分"
    end
    
    return concat(result)
end

-- 星期转换
function zhnumber.weekday(year, month, day)
    -- 支持单字符串参数或三个参数
    if not month and not day then
        local str = year
        year, month, day = match(str, "^(%d+)/(%d+)/(%d+)$")
    end
    
    if not year or not month or not day then
        return ""
    end
    
    -- Zeller公式计算星期
    local y, m, d = tonumber(year), tonumber(month), tonumber(day)
    
    if m < 3 then
        y = y - 1
        m = m + 12
    end
    
    local c = floor(y / 100)
    y = y % 100
    
    local w = (d + floor((m + 1) * 2.6) + y + floor(y / 4) + floor(c / 4) - 2 * c) % 7
    
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

-- 注册转换器
converters.zhnumber = zhnumber.convert
converters.zhdate = zhnumber.date
converters.zhtime = zhnumber.time
converters.zhweekday = zhnumber.weekday
converters.zhtiangan = zhnumber.tiangan
converters.zhdizhi = zhnumber.dizhi
converters.zhganzhi = zhnumber.ganzhi
converters.zhganzhinian = zhnumber.ganzhinian
