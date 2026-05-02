if not modules then modules = { } end modules ['m-pinyin'] = {
    version   = 1.0,
    comment   = "Pinyin support for ConTeXt",
    author    = "Based on xpinyin for LaTeX",
}

local insert, concat = table.insert, table.concat
local gmatch, gsub, find, sub = string.gmatch, string.gsub, string.find, string.sub
local tonumber, type, next = tonumber, type, next
local utfbyte, utfcharacters = utf.byte, utf.characters

local pinyin_data = pinyin_data or { }
local data_loaded = false

local settings = {
    multiple = false,
    markpolyphone = false,
}

local function setup(t)
    if t.multiple == "yes" then
        settings.multiple = true
    else
        settings.multiple = false
    end
    if t.markpolyphone == "yes" then
        settings.markpolyphone = true
    else
        settings.markpolyphone = false
    end
end

local tone_marks = {
    a = { "ā", "á", "ǎ", "à" },
    e = { "ē", "é", "ě", "è" },
    i = { "ī", "í", "ǐ", "ì" },
    o = { "ō", "ó", "ǒ", "ò" },
    u = { "ū", "ú", "ǔ", "ù" },
    ü = { "ǖ", "ǘ", "ǚ", "ǜ" },
    v = { "ǖ", "ǘ", "ǚ", "ǜ" },
}

local function convert_tone(syllable, tone)
    tone = tonumber(tone) or 0
    if tone < 1 or tone > 4 then
        return syllable
    end
    
    syllable = gsub(syllable, "v", "ü")
    
    local a_pos = find(syllable, "a")
    if a_pos then
        local before = sub(syllable, 1, a_pos - 1)
        local after = sub(syllable, a_pos + 1)
        return before .. tone_marks.a[tone] .. after
    end
    
    local e_pos = find(syllable, "e")
    if e_pos then
        local before = sub(syllable, 1, e_pos - 1)
        local after = sub(syllable, e_pos + 1)
        return before .. tone_marks.e[tone] .. after
    end
    
    local ou_pos = find(syllable, "ou")
    if ou_pos then
        local before = sub(syllable, 1, ou_pos)
        local after = sub(syllable, ou_pos + 2)
        return before .. tone_marks.u[tone] .. after
    end
    
    local last_vowel = 0
    local vowel_chars = { "a", "e", "i", "o", "u", "ü" }
    for i = 1, #syllable do
        local char = sub(syllable, i, i)
        for _, v in next, vowel_chars do
            if char == v then
                last_vowel = i
                break
            end
        end
    end
    
    if last_vowel > 0 then
        local char = sub(syllable, last_vowel, last_vowel)
        local before = sub(syllable, 1, last_vowel - 1)
        local after = sub(syllable, last_vowel + 1)
        if tone_marks[char] then
            return before .. tone_marks[char][tone] .. after
        end
    end
    
    return syllable
end

local function parse_pinyin_line(line)
    if not line or sub(line, 1, 1) == "#" then
        return nil
    end
    
    local code_point, pinyins = line:match("U%+([0-9A-Fa-f]+):%s*([^#]*)")
    if not code_point then
        return nil
    end
    
    code_point = tonumber(code_point, 16)
    if not code_point then
        return nil
    end
    
    pinyins = pinyins:gsub("%s+$", "")
    if pinyins == "" then
        return nil
    end
    
    local result = { }
    for pinyin in gmatch(pinyins, "[^,%s]+") do
        if pinyin ~= "" then
            insert(result, pinyin)
        end
    end
    
    if #result == 0 then
        return nil
    end
    
    return code_point, result
end

local function load_pinyin_data()
    if data_loaded then
        return true
    end
    
    local filename = resolvers and resolvers.findfile("pinyin.txt") or "data-index/pinyin.txt"
    local file = io.open(filename, "r")
    
    if not file then
        log.report("pinyin", "warning", "Cannot find pinyin data file: %s", filename)
        return false
    end
    
    for line in file:lines() do
        local code_point, pinyins = parse_pinyin_line(line)
        if code_point and pinyins then
            pinyin_data[code_point] = pinyins
        end
    end
    
    file:close()
    data_loaded = true
    
    return true
end

local function format_pinyin(pinyin_str)
    if not pinyin_str then
        return ""
    end
    
    for char in gmatch(pinyin_str, "([%z\1-\127\194-\244][\128-\191]*)") do
        local code = utfbyte(char)
        if code and (
            (code >= 0x00C0 and code <= 0x00FF) or
            (code >= 0x0100 and code <= 0x024F) or
            (code >= 0x1E00 and code <= 0x1EFF)
        ) then
            return pinyin_str
        end
    end
    
    local base, tone = pinyin_str:match("([a-zA-Zü]+)([1-5]?)")
    if not base then
        return pinyin_str
    end
    
    tone = tonumber(tone) or 0
    
    if tone == 0 or tone == 5 then
        return base
    end
    
    return convert_tone(base, tone)
end

local function set_pinyin(char, pinyin)
    local code = type(char) == "number" and char or utfbyte(char)
    if not code then
        return false
    end
    
    if not pinyin_data[code] then
        pinyin_data[code] = { }
    end
    
    if type(pinyin) == "table" then
        pinyin_data[code] = pinyin
    else
        pinyin_data[code][1] = pinyin
    end
    
    return true
end

local function format_pinyin_string(pinyin_str)
    if not pinyin_str or pinyin_str == "" then
        return ""
    end
    
    local result = { }
    local current = ""
    local i = 1
    
    while i <= #pinyin_str do
        local char = sub(pinyin_str, i, i)
        
        if char:match("[a-zA-Züv]") then
            current = current .. char
        elseif char:match("[1-5]") then
            if current ~= "" then
                local formatted = format_pinyin(current .. char)
                insert(result, formatted)
                current = ""
            end
        else
            if current ~= "" then
                insert(result, current)
                current = ""
            end
        end
        
        i = i + 1
    end
    
    if current ~= "" then
        insert(result, current)
    end
    
    context(concat(result, " "))
end

local framed_prefix = "\\framed[frame=on,framecolor=red,location=low,rulethickness=0.4pt,background=,offset=0pt,strut=no]{"
local framed_suffix = "}"

local function output_annotated(char, py, markpolyphone, is_polyphone, use_context)
    if markpolyphone and is_polyphone then
        if py and py ~= "" then
            if use_context then
                context(framed_prefix .. "\\pinyinannotate{")
                context(char)
                context("}{")
                context(py)
                context("}{false}" .. framed_suffix)
            else
                return framed_prefix .. "\\pinyinannotate{" .. char .. "}{" .. py .. "}{false}" .. framed_suffix
            end
        else
            if use_context then
                context(framed_prefix)
                context(char)
                context(framed_suffix)
            else
                return framed_prefix .. char .. framed_suffix
            end
        end
    else
        if py and py ~= "" then
            if use_context then
                context.pinyinannotate(char, py, is_polyphone and "true" or "false")
            else
                return "\\pinyinannotate{" .. char .. "}{" .. py .. "}{false}"
            end
        else
            if use_context then
                context(char)
            else
                return char
            end
        end
    end
end

local function get_pinyin_info(code, multiple)
    local all_pinyins = pinyin_data[code]
    local is_polyphone = all_pinyins and #all_pinyins > 1
    local py
    
    if multiple then
        if all_pinyins and #all_pinyins > 0 then
            local formatted = {}
            for _, p in next, all_pinyins do
                insert(formatted, format_pinyin(p))
            end
            py = concat(formatted, " ")
        end
    else
        if all_pinyins then
            py = format_pinyin(all_pinyins[1])
        end
    end
    
    return py, is_polyphone
end

local function process_buffer(bufname, manual_pinyin)
    local content = buffers.getcontent(bufname or "pinyinscope")
    
    if not content or content == "" then
        return
    end
    
    if bufname == "xpinyinbuf" then
        local result = {}
        
        for char in utfcharacters(content) do
            local byte = utfbyte(char)
            
            if byte and byte >= 0x4E00 and byte <= 0x9FFF then
                local py, is_polyphone
                
                if manual_pinyin and manual_pinyin ~= "" then
                    py = format_pinyin(manual_pinyin)
                    local all_pinyins = pinyin_data[byte]
                    is_polyphone = all_pinyins and #all_pinyins > 1
                else
                    py, is_polyphone = get_pinyin_info(byte, settings.multiple)
                end
                
                insert(result, output_annotated(char, py, settings.markpolyphone, is_polyphone, false))
            else
                insert(result, char)
            end
        end
        
        context(concat(result))
    else
        local processed = {}
        local counter = 0
        
        content = gsub(content, "\\xpinyin%s*%[([^%]]*)%]%s*%{([^%}]*)%}", function(py, chars)
            local result = {}
            for char in utfcharacters(chars) do
                local byte = utfbyte(char)
                if byte and byte >= 0x4E00 and byte <= 0x9FFF then
                    local formatted_py = format_pinyin(py)
                    local all_pinyins = pinyin_data[byte]
                    local is_polyphone = all_pinyins and #all_pinyins > 1
                    insert(result, output_annotated(char, formatted_py, settings.markpolyphone, is_polyphone, false))
                else
                    insert(result, char)
                end
            end
            counter = counter + 1
            processed[counter] = concat(result)
            return "\x00XPY" .. counter .. "YPX\x00"
        end)
        
        content = gsub(content, "[\228-\233][\128-\191][\128-\191]", function(char)
            local byte = utfbyte(char)
            if byte and byte >= 0x4E00 and byte <= 0x9FFF then
                local py, is_polyphone = get_pinyin_info(byte, settings.multiple)
                return output_annotated(char, py, settings.markpolyphone, is_polyphone, false)
            end
            return char
        end)
        
        content = gsub(content, "\x00XPY(%d+)YPX\x00", function(marker)
            return processed[tonumber(marker)]
        end)
        
        context(content)
    end
end

thirddata            = thirddata or { }
local pinyin         = thirddata.pinyin or { }
thirddata.pinyin     = pinyin

pinyin.setup         = setup
pinyin.set           = set_pinyin
pinyin.format_pinyin_string = format_pinyin_string
pinyin.process_buffer = process_buffer

load_pinyin_data()

return pinyin
