local sorters           = sorters or { }
local definitions       = sorters.definitions or { }

local pinyin_data = nil
local pinyin_file = "pinyin.txt"

local stroke_data = nil
local stroke_file = "sunwb_strokeorder.txt"

local digitsoffset      = 0x20000 -- frozen
local digitsmaximum     = 0xFFFFF -- frozen

local function is_digit_char(c)
    local byte = utf.byte(c, 1)
    if byte and byte >= digitsoffset and byte <= digitsmaximum then
        return true
    end
    if c:match("^[0-9]$") then
        return true
    end
    if c:match("^[0-9]+$") then
        return true
    end
    return false
end

local function load_stroke_data()
    if stroke_data then
        return stroke_data
    end
    
    local data = io.loaddata(resolvers and resolvers.findfile(stroke_file) or stroke_file)
    if not data then
        return nil
    end
    
    stroke_data = {}
    
    for line in string.gmatch(data, "([^\r\n]+)") do
        if not line:match("^#") then
            local char, stroke_code = line:match("^(%S+)%s*(%d+)")
            if char and stroke_code then
                local stroke_count = #tostring(stroke_code)
                stroke_data[char] = {
                    count = stroke_count,
                    code = stroke_code
                }
            end
        end
    end
    
    return stroke_data
end

local function load_pinyin_data()
    if pinyin_data then
        return pinyin_data
    end
    
    local data = io.loaddata(resolvers and resolvers.findfile(pinyin_file) or pinyin_file)
    if not data then
        return nil
    end
    
    pinyin_data = {}
    
    for line in string.gmatch(data, "([^\r\n]+)") do
        if not line:match("^#") then
            local pinyin_raw, char = line:match("U%+[0-9A-Fa-f]+:%s*([^#]+)#%s*(%S+)")
            if pinyin_raw and char then
                pinyin_raw = pinyin_raw:gsub("^%s+", ""):gsub("%s+$", "")
                local pinyin = pinyin_raw:match("^([^,]+)")
                if pinyin then
                    pinyin = pinyin:gsub("^%s+", ""):gsub("%s+$", "")
                    pinyin_data[char] = pinyin
                end
            end
        end
    end
    
    return pinyin_data
end

local function remove_tone(s)
    local tone_map = {
        ["ā"] = "a", ["á"] = "a", ["ǎ"] = "a", ["à"] = "a",
        ["ē"] = "e", ["é"] = "e", ["ě"] = "e", ["è"] = "e",
        ["ī"] = "i", ["í"] = "i", ["ǐ"] = "i", ["ì"] = "i",
        ["ō"] = "o", ["ó"] = "o", ["ǒ"] = "o", ["ò"] = "o",
        ["ū"] = "u", ["ú"] = "u", ["ǔ"] = "u", ["ù"] = "u",
        ["ǖ"] = "v", ["ǘ"] = "v", ["ǚ"] = "v", ["ǜ"] = "v", ["ü"] = "v",
        ["ń"] = "n", ["ň"] = "n", ["ǹ"] = "n",
        ["ḿ"] = "m",
    }
    return s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return tone_map[c] or c
    end)
end

local function build_pinyin()
    local data = load_pinyin_data()
    if not data then
        return { entries = {}, orders = {} }
    end
    
    local sorted = {}
    for char, pinyin in pairs(data) do
        sorted[#sorted + 1] = { char, remove_tone(pinyin) }
    end
    
    table.sort(sorted, function(a, b)
        if a[2] ~= b[2] then
            return a[2] < b[2]
        end
        return a[1] < b[1]
    end)
    
    local entries = {}
    local orders = {}
    
    for i, entry in ipairs(sorted) do
        orders[#orders + 1] = entry[1]
        entries[entry[1]] = entry[2]
    end
    
    local digits = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
    orders[#orders + 1] = "number"
    entries["number"] = "99999"
    for _, digit in ipairs(digits) do
        orders[#orders + 1] = digit
        entries[digit] = "number"
    end
    
    local western = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
                     "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z" }
    orders[#orders + 1] = "alpha"
    entries["alpha"] = "99998"
    for _, letter in ipairs(western) do
        orders[#orders + 1] = letter
        entries[letter] = "alpha"
    end
    
    return { entries = entries, orders = orders }
end

local function build_alpha()
    local data = load_pinyin_data()
    if not data then
        return { entries = {}, orders = {} }
    end
    
    local sorted = {}
    for char, pinyin in pairs(data) do
        sorted[#sorted + 1] = { char, remove_tone(pinyin) }
    end
    
    table.sort(sorted, function(a, b)
        if a[2] ~= b[2] then
            return a[2] < b[2]
        end
        return a[1] < b[1]
    end)
    
    local entries = {}
    local orders = {}
    
    local western = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" }
    
    local by_letter = {}
    for _, letter in ipairs(western) do
        by_letter[letter] = {}
    end
    
    for _, entry in ipairs(sorted) do
        local first = entry[2]:sub(1, 1)
        local first_lower = first:lower()
        if by_letter[first_lower] then
            table.insert(by_letter[first_lower], entry)
        end
    end
    
    for _, letter in ipairs(western) do
        table.sort(by_letter[letter], function(a, b)
            if a[2] ~= b[2] then
                return a[2] < b[2]
            end
            return a[1] < b[1]
        end)
    end
    
    for _, letter in ipairs(western) do
        orders[#orders + 1] = letter
        entries[letter] = letter
        entries[letter:upper()] = letter
        
        for _, entry in ipairs(by_letter[letter]) do
            orders[#orders + 1] = entry[1]
            entries[entry[1]] = letter
        end
    end
    
    local digits = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
    orders[#orders + 1] = "number"
    entries["number"] = "99999"
    for _, digit in ipairs(digits) do
        orders[#orders + 1] = digit
        entries[digit] = "number"
    end
    
    return { entries = entries, orders = orders }
end

local function build_stroke()
    local data = load_stroke_data()
    if not data then
        return { entries = {}, orders = {} }
    end
    
    local entries = {}
    local orders = {}
    
    local by_stroke = {}
    for char, stroke_info in pairs(data) do
        -- Skip Unicode offset characters (0x20000-0xFFFFF) as they should be treated as numbers
        local byte = utf.byte(char, 1)
        if byte and byte >= digitsoffset and byte <= digitsmaximum then
            -- Skip this character
        else
            if not by_stroke[stroke_info.count] then
                by_stroke[stroke_info.count] = {}
            end
            table.insert(by_stroke[stroke_info.count], char)
        end
    end
    
    local stroke_numbers = {}
    for strokes in pairs(by_stroke) do
        table.insert(stroke_numbers, strokes)
    end
    table.sort(stroke_numbers, function(a, b)
        return tonumber(a) < tonumber(b)
    end)
    
    for _, strokes in ipairs(stroke_numbers) do
        local stroke_name = strokes .. "画"
        local sort_key = string.format("%05d", strokes)
        orders[#orders + 1] = stroke_name
        entries[stroke_name] = sort_key
        
        table.sort(by_stroke[strokes], function(a, b)
            return data[a].code < data[b].code
        end)
        for _, char in ipairs(by_stroke[strokes]) do
            orders[#orders + 1] = char
            entries[char] = stroke_name
        end
    end
    
    local digits = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
    orders[#orders + 1] = "number"
    entries["number"] = "99999"
    for _, digit in ipairs(digits) do
        orders[#orders + 1] = digit
        entries[digit] = "number"
    end
    
    local western = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
                     "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z" }
    orders[#orders + 1] = "alpha"
    entries["alpha"] = "99998"
    for _, letter in ipairs(western) do
        orders[#orders + 1] = letter
        entries[letter] = "alpha"
    end
    
    return { entries = entries, orders = orders }
end

local pinyin_def = build_pinyin()
local alpha_def = build_alpha()
local stroke_def = build_stroke()

definitions["zh-pinyin"] = {
    entries = pinyin_def.entries,
    orders = pinyin_def.orders,
    firstofsplit = function(first, data, entry)
        if is_digit_char(first) then
            return first, "number"
        end
        return first, pinyin_def.entries[first] or "\000"
    end
}

definitions["zh-alpha"] = {
    entries = alpha_def.entries,
    orders = alpha_def.orders,
    firstofsplit = function(first, data, entry)
        if is_digit_char(first) then
            return first, "number"
        end
        return first, alpha_def.entries[first] or "\000"
    end
}

definitions["zh-stroke"] = {
    entries = stroke_def.entries,
    orders = stroke_def.orders,
    firstofsplit = function(first, data, entry)
        local result_key, result_entry
        if is_digit_char(first) then
            result_key = "99999"
            result_entry = "number"
        elseif first:match("画$") then
            local strokes = tonumber(first:match("^(%d+)画"))
            if strokes then
                local sort_key = string.format("%05d", strokes)
                result_key = sort_key
                result_entry = sort_key
            else
                result_key = first
                result_entry = stroke_def.entries[first] or "\000"
            end
        else
            result_key = first
            result_entry = stroke_def.entries[first] or "\000"
        end
        return result_key, result_entry
    end
}
