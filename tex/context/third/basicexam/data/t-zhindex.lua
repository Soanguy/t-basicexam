-- m-zhindex.lua
-- 中文索引排序器：zh-pinyin / zh-alpha / zh-stroke
-- 数据源：
--   pinyin-data.lua   由 m-pinyin.lua 生成
--   stroke-data.lua   由 make_stroke_data.py 生成
--
-- 关于扩展 B 区汉字与 ConTeXt numify 的冲突：
--   ConTeXt 的 sort-ini.lua 在数字排序时把 "0" 变成 utfchar(0x20000+n)，
--   0x20000-0x2A6DF 恰好是 CJK 扩展 B 区码点。若 entries 表包含扩展 B 区
--   汉字，numify 后的数字会误命中这些条目，被错误归类。
--   本模块在加载时过滤掉扩展 B 区汉字，避免冲突。
--
-- 优化 1：build_pinyin 和 build_alpha 合并为一次遍历、一次排序。
-- 优化 2：load_stroke_data 的过滤合并进 build_stroke，只遍历一次。
-- 优化 3：remove_tone 加缓存，重复拼音不重复转换。
-- 优化 4：load_pinyin_data 与构建合并，只遍历一次原始数据。

local sorters     = sorters     or { }
local definitions = sorters.definitions or { }
local thirddata   = thirddata   or { }

-- ============================================================
-- 声调去除（带缓存）
-- ============================================================

local tone_map = {
    ["ā"]="a", ["á"]="a", ["ǎ"]="a", ["à"]="a",
    ["ē"]="e", ["é"]="e", ["ě"]="e", ["è"]="e",
    ["ī"]="i", ["í"]="i", ["ǐ"]="i", ["ì"]="i",
    ["ō"]="o", ["ó"]="o", ["ǒ"]="o", ["ò"]="o",
    ["ū"]="u", ["ú"]="u", ["ǔ"]="u", ["ù"]="u",
    ["ǖ"]="v", ["ǘ"]="v", ["ǚ"]="v", ["ǜ"]="v", ["ü"]="v",
    ["ń"]="n", ["ň"]="n", ["ǹ"]="n",
    ["ḿ"]="m",
}

local tone_cache = { }

local function remove_tone(s)
    if not s or s == "" then
        return s
    end
    local cached = tone_cache[s]
    if cached then
        return cached
    end
    local result = s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return tone_map[c] or c
    end)
    tone_cache[s] = result
    return result
end

-- ============================================================
-- 数据过滤
-- ============================================================

-- 保留：基本区 + 扩展 A + 兼容汉字区
local function is_index_hanzi(cp)
    return (cp >= 0x3400 and cp <= 0x4DBF)     -- 扩展 A
        or (cp >= 0x4E00 and cp <= 0x9FFF)     -- 基本区
        or (cp >= 0xF900 and cp <= 0xFAFF)     -- 兼容汉字
end

local function is_digit_char(c)
    if not c or c == "" then
        return false
    end
    if c:match("^[0-9]+$") then
        return true
    end
    -- numify 后的数字字符：U+20000-U+FFFFF，UTF-8 4 字节首字节 0xF0-0xF3
    local b = c:byte(1)
    if b and b >= 0xF0 and b <= 0xF3 then
        return true
    end
    return false
end

-- ============================================================
-- 原始数据读取（只读，不做处理）
-- ============================================================

local function load_pinyin_raw()
    if thirddata.pinyin_raw then
        return thirddata.pinyin_raw
    end
    local f = resolvers and resolvers.findfile("pinyin-data.lua")
    if not f then return nil end
    local chunk = loadfile(f)
    if not chunk then return nil end
    local ok, raw = pcall(chunk)
    if not ok or type(raw) ~= "table" then return nil end
    thirddata.pinyin_raw = raw
    return raw
end

local function load_stroke_raw()
    local f = resolvers and resolvers.findfile("stroke-data.lua")
    if not f then return nil end
    local chunk = loadfile(f)
    if not chunk then return nil end
    local ok, raw = pcall(chunk)
    if not ok or type(raw) ~= "table" then return nil end
    return raw
end

-- ============================================================
-- 数字转汉字（笔画标题用）
-- ============================================================

local HANZI_DIGITS = { "零", "一", "二", "三", "四", "五", "六", "七", "八", "九" }

local function num_to_hanzi(n)
    if not n or n < 1 or n > 99 then
        return tostring(n)
    end
    if n < 10 then
        return HANZI_DIGITS[n + 1]
    end
    if n == 10 then
        return "十"
    end
    if n < 20 then
        return "十" .. HANZI_DIGITS[n - 10 + 1]
    end
    local tens = math.floor(n / 10)
    local ones = n % 10
    if ones == 0 then
        return HANZI_DIGITS[tens + 1] .. "十"
    end
    return HANZI_DIGITS[tens + 1] .. "十" .. HANZI_DIGITS[ones + 1]
end

-- ============================================================
-- 公共常量
-- ============================================================

local DIGITS = { "0","1","2","3","4","5","6","7","8","9" }

local WESTERN_LOWER = {
    "a","b","c","d","e","f","g","h","i","j","k","l","m",
    "n","o","p","q","r","s","t","u","v","w","x","y","z",
}

local WESTERN_BOTH = {
    "a","b","c","d","e","f","g","h","i","j","k","l","m",
    "n","o","p","q","r","s","t","u","v","w","x","y","z",
    "A","B","C","D","E","F","G","H","I","J","K","L","M",
    "N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
}

-- 追加 number 分组到 orders / entries
local function append_number(orders, entries)
    orders[#orders + 1] = "number"
    entries["number"] = "99999"
    for i = 1, #DIGITS do
        local d = DIGITS[i]
        orders[#orders + 1] = d
        entries[d] = "number"
    end
end

-- 追加 alpha 分组（含大小写字母）到 orders / entries
local function append_alpha_both(orders, entries)
    orders[#orders + 1] = "alpha"
    entries["alpha"] = "99998"
    for i = 1, #WESTERN_BOTH do
        local l = WESTERN_BOTH[i]
        orders[#orders + 1] = l
        entries[l] = "alpha"
    end
end

-- ============================================================
-- 拼音排序数据：一次遍历、一次排序，同时产出 pinyin 和 alpha
-- ============================================================

local function build_pinyin_and_alpha()
    local raw = load_pinyin_raw()
    if not raw then
        return { entries = { }, orders = { } },
               { entries = { }, orders = { } }
    end

    -- 过滤 + 去调 + 收集
    local utf_char = utf.char
    local sorted = { }
    local n = 0
    for cp, pinyins in pairs(raw) do
        if is_index_hanzi(cp) then
            local first = pinyins[1]
            if first then
                n = n + 1
                sorted[n] = { utf_char(cp), remove_tone(first) }
            end
        end
    end

    -- 一次排序，pinyin 和 alpha 共用
    table.sort(sorted, function(a, b)
        if a[2] ~= b[2] then
            return a[2] < b[2]
        end
        return a[1] < b[1]
    end)

    -- ---------------- zh-pinyin ----------------
    local p_entries, p_orders = { }, { }
    for i = 1, n do
        local e = sorted[i]
        p_orders[#p_orders + 1] = e[1]
        p_entries[e[1]] = e[2]
    end
    append_number(p_orders, p_entries)
    append_alpha_both(p_orders, p_entries)

    -- ---------------- zh-alpha ----------------
    local a_entries, a_orders = { }, { }

    local by_letter = { }
    for i = 1, #WESTERN_LOWER do
        by_letter[WESTERN_LOWER[i]] = { }
    end

    for i = 1, n do
        local e = sorted[i]
        local first = e[2]:sub(1, 1):lower()
        local bucket = by_letter[first]
        if bucket then
            bucket[#bucket + 1] = e
        end
    end

    -- 每个字母下的条目已因 sorted 全局有序而保持拼音顺序，无需再次排序
    for i = 1, #WESTERN_LOWER do
        local letter = WESTERN_LOWER[i]
        a_orders[#a_orders + 1] = letter
        a_entries[letter] = letter
        a_entries[letter:upper()] = letter
        local bucket = by_letter[letter]
        for j = 1, #bucket do
            local e = bucket[j]
            a_orders[#a_orders + 1] = e[1]
            a_entries[e[1]] = letter
        end
    end
    append_number(a_orders, a_entries)

    return
        { entries = p_entries, orders = p_orders },
        { entries = a_entries, orders = a_orders }
end

-- ============================================================
-- 笔画排序数据：过滤 + 分组一次完成
-- ============================================================

local function build_stroke()
    local raw = load_stroke_raw()
    if not raw then
        return { entries = { }, orders = { } }
    end

    -- 过滤扩展 B 区（首字节 0xF0-0xF3）并按笔画数分组
    local by_stroke = { }
    for char, code in pairs(raw) do
        local b = char:byte(1)
        if b and b < 0xF0 then
            local cnt = #code
            local bucket = by_stroke[cnt]
            if not bucket then
                bucket = { }
                by_stroke[cnt] = bucket
            end
            -- 直接存 { char, code }，后面比较用 e[2]，不再回查 raw
            bucket[#bucket + 1] = { char, code }
        end
    end

    -- 笔画数排序
    local stroke_numbers = { }
    for strokes in pairs(by_stroke) do
        stroke_numbers[#stroke_numbers + 1] = strokes
    end
    table.sort(stroke_numbers, function(a, b)
        return tonumber(a) < tonumber(b)
    end)

    -- 组装
    local entries, orders = { }, { }
    for i = 1, #stroke_numbers do
        local strokes = stroke_numbers[i]
        local stroke_name = num_to_hanzi(tonumber(strokes)) .. "画"
        local sort_key = string.format("%05d", strokes)
        orders[#orders + 1] = stroke_name
        entries[stroke_name] = sort_key

        local bucket = by_stroke[strokes]
        table.sort(bucket, function(a, b)
            return a[2] < b[2]
        end)
        for j = 1, #bucket do
            local e = bucket[j]
            orders[#orders + 1] = e[1]
            entries[e[1]] = stroke_name
        end
    end

    append_number(orders, entries)
    append_alpha_both(orders, entries)

    return { entries = entries, orders = orders }
end

-- ============================================================
-- 注册定义
-- ============================================================

local pinyin_def, alpha_def = build_pinyin_and_alpha()
local stroke_def = build_stroke()

definitions["zh-pinyin"] = {
    entries = pinyin_def.entries,
    orders  = pinyin_def.orders,
    firstofsplit = function(first, data, entry)
        if is_digit_char(first) then
            return "number", "number"
        end
        return first, pinyin_def.entries[first] or "\000"
    end,
}

definitions["zh-alpha"] = {
    entries = alpha_def.entries,
    orders  = alpha_def.orders,
    firstofsplit = function(first, data, entry)
        if is_digit_char(first) then
            return "number", "number"
        end
        return first, alpha_def.entries[first] or "\000"
    end,
}

definitions["zh-stroke"] = {
    entries = stroke_def.entries,
    orders  = stroke_def.orders,
    firstofsplit = function(first, data, entry)
        local result_key, result_entry
        if is_digit_char(first) then
            result_key, result_entry = "number", "number"
        elseif first:match("画$") then
            local strokes = tonumber(first:match("^(%d+)画"))
            if strokes then
                local sort_key = string.format("%05d", strokes)
                result_key, result_entry = sort_key, sort_key
            else
                result_key = first
                result_entry = stroke_def.entries[first] or "\000"
            end
        else
            result_key = first
            result_entry = stroke_def.entries[first] or "\000"
        end
        return result_key, result_entry
    end,
}