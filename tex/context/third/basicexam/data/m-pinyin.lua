if not modules then modules = { } end modules ['m-pinyin'] = {
    version   = 1.1,
    comment   = "Pinyin support for ConTeXt",
    author    = "Based on xpinyin for LaTeX",
}

local insert, concat = table.insert, table.concat
local gmatch, gsub, find, sub = string.gmatch, string.gsub, string.find, string.sub
local tonumber, type, next = tonumber, type, next
local utfbyte = utf.byte

-- ---------------------------------------------------------------------------
-- UTF-8 helpers
-- ---------------------------------------------------------------------------

local function utf8chars(s)
    local i, len = 1, #s
    return function()
        if i > len then return nil end
        local b = s:byte(i)
        if not b then return nil end
        local n = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
        if i + n - 1 > len then n = 1 end  -- truncated sequence
        local c = sub(s, i, i + n - 1)
        i = i + n
        return c
    end
end

local function is_hanzi(code)
    if not code then return false end
    return (code >= 0x4E00  and code <= 0x9FFF)   -- basic
        or (code >= 0x3400  and code <= 0x4DBF)   -- ext A
        or (code >= 0xF900  and code <= 0xFAFF)   -- compatibility
        or (code >= 0x20000 and code <= 0x2EBEF)  -- ext B-F
        or (code >= 0x30000 and code <= 0x323AF)  -- ext G-H
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local pinyin_data = { }
local data_loaded = false
local load_attempted  = false

local settings = {
    multiple       = false,
    markpolyphone  = false,
}

local function setup(t)
    settings.multiple      = (t.multiple      == "yes")
    settings.markpolyphone = (t.markpolyphone == "yes")
end

-- ---------------------------------------------------------------------------
-- Tone conversion
-- ---------------------------------------------------------------------------

local tone_marks = {
    a = { "\u{0101}", "\u{00E1}", "\u{01CE}", "\u{00E0}" },
    e = { "\u{0113}", "\u{00E9}", "\u{011B}", "\u{00E8}" },
    i = { "\u{012B}", "\u{00ED}", "\u{01D0}", "\u{00EC}" },
    o = { "\u{014D}", "\u{00F3}", "\u{01D2}", "\u{00F2}" },
    u = { "\u{016B}", "\u{00FA}", "\u{01D4}", "\u{00F9}" },
    ü = { "\u{01D6}", "\u{01D8}", "\u{01DA}", "\u{01DC}" },
    v = { "\u{01D6}", "\u{01D8}", "\u{01DA}", "\u{01DC}" },
}

local function convert_tone(syllable, tone)
    tone = tonumber(tone) or 0
    if tone < 1 or tone > 4 then
        return syllable
    end

    local first_char = sub(syllable, 1, 1)
    local omit_dots = (first_char == "j" or first_char == "q" or first_char == "x")

    syllable = gsub(syllable, "v", "ü")
    if omit_dots then
        syllable = gsub(syllable, "ü", "u")
    end

    local vowels = { }
    local byte_pos = 1
    for uchar in utf8chars(syllable) do
        if tone_marks[uchar] then
            insert(vowels, { char = uchar, byte = byte_pos, len = #uchar })
        end
        byte_pos = byte_pos + #uchar
    end

    if #vowels == 0 then
        return syllable
    end

    -- Priority: a > o > e > last vowel
    local priority = { a = 1, o = 2, e = 3 }
    local target, bestp = nil, math.huge
    for i = 1, #vowels do
        local v = vowels[i]
        local p = priority[v.char] or (4 + (#vowels - i))
        if p < bestp then
            target, bestp = v, p
        end
    end

    local before = sub(syllable, 1, target.byte - 1)
    local after  = sub(syllable, target.byte + target.len)
    return before .. tone_marks[target.char][tone] .. after
end

local function format_pinyin(pinyin_str)
    if not pinyin_str then
        return ""
    end

    -- Already has tone marks?
    for char in gmatch(pinyin_str, "([%z\1-\127\194-\244][\128-\191]*)") do
        local code = utfbyte(char)
        if code and code ~= 0x00FC and (
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

-- ---------------------------------------------------------------------------
-- Data loading
-- ---------------------------------------------------------------------------

-- local function parse_pinyin_line(line)
--     if not line or sub(line, 1, 1) == "#" then
--         return nil
--     end

--     local code_point, pinyins = line:match("U%+([0-9A-Fa-f]+):%s*([^#]*)")
--     if not code_point then
--         return nil
--     end

--     code_point = tonumber(code_point, 16)
--     if not code_point then
--         return nil
--     end

--     pinyins = pinyins:gsub("%s+$", "")
--     if pinyins == "" then
--         return nil
--     end

--     local result = { }
--     for pinyin in gmatch(pinyins, "[^,%s]+") do
--         if pinyin ~= "" then
--             insert(result, pinyin)
--         end
--     end

--     if #result == 0 then
--         return nil
--     end

--     return code_point, result
-- end

local function load_pinyin_data()
    local filename = resolvers and resolvers.findfile("pinyin-data.lua")
                     or "data-index/pinyin-data.lua"
    if not filename then
        return false
    end

    local chunk, err = loadfile(filename)
    if not chunk then
        return false
    end

    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then
        return false
    end

    pinyin_data = data
    return true
end

local function ensure_data()
    if data_loaded then return end
    if load_attempted then return end
    load_attempted = true
    if load_pinyin_data() then
        data_loaded = true
    end
end

-- ---------------------------------------------------------------------------
-- User API
-- ---------------------------------------------------------------------------

local function set_pinyin(char, pinyin, replace_all)
    ensure_data()
    
    local code = type(char) == "number" and char or utfbyte(char)
    if not code then
        return false
    end

    if not pinyin_data[code] then
        pinyin_data[code] = { }
    end

    if type(pinyin) == "table" then
        pinyin_data[code] = pinyin
    elseif replace_all then
        pinyin_data[code] = { pinyin }
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

    for uchar in utf8chars(pinyin_str) do
        local byte = utfbyte(uchar)
        if (byte >= 0x0041 and byte <= 0x005A) or
           (byte >= 0x0061 and byte <= 0x007A) or
           byte == 0x00FC or byte == 0x0076 then
            current = current .. uchar
        elseif byte >= 0x0031 and byte <= 0x0035 then
            if current ~= "" then
                insert(result, format_pinyin(current .. uchar))
                current = ""
            end
        else
            if current ~= "" then
                insert(result, current)
                current = ""
            end
        end
    end

    if current ~= "" then
        insert(result, current)
    end

    context(concat(result, " "))
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local framed_prefix = "\\hskip.5pt\\relax\\framed[frame=on,framecolor=lightred,location=low,offset=0pt,rulethickness=0.4pt,background=color,backgroundcolor=lightred,foregroundcolor=white]{"
local framed_suffix = "}\\hskip.5pt\\relax"

local function render_annotated(char, py, markpolyphone, is_polyphone)
    if markpolyphone and is_polyphone then
        if py and py ~= "" then
            return framed_prefix .. "\\pinyinannotate{" .. char .. "}{" .. py .. "}{false}" .. framed_suffix
        else
            return framed_prefix .. char .. framed_suffix
        end
    else
        if py and py ~= "" then
            return "\\pinyinannotate{" .. char .. "}{" .. py .. "}{false}"
        else
            return char
        end
    end
end

local function get_pinyin_info(code, multiple)
    local all_pinyins = pinyin_data[code]
    local is_polyphone = all_pinyins and #all_pinyins > 1
    local py

    if multiple then
        if all_pinyins and #all_pinyins > 0 then
            -- Already converted at load time
            py = concat(all_pinyins, " ")
        end
    else
        if all_pinyins then
            py = all_pinyins[1]
        end
    end

    return py, is_polyphone
end

-- ---------------------------------------------------------------------------
-- Buffer processing
-- ---------------------------------------------------------------------------

local function process_buffer(bufname, manual_pinyin)
    ensure_data()
    local content = buffers.getcontent(bufname or "pinyinscope")
    if not content or content == "" then
        return
    end

    if bufname == "xpinyinbuf" then
        -- Split manual pinyin into a list
        local manual_list = nil
        if manual_pinyin and manual_pinyin ~= "" then
            manual_list = { }
            for p in gmatch(manual_pinyin, "[^,%s]+") do
                insert(manual_list, p)
            end
            if #manual_list == 0 then manual_list = nil end
        end

        local result = { }
        local idx = 0

        for char in utf8chars(content) do
            local byte = utfbyte(char)
            if is_hanzi(byte) then
                idx = idx + 1
                local py, is_polyphone

                if manual_list then
                    local mp = manual_list[idx] or manual_list[1]
                    py = format_pinyin(mp)
                    local all_pinyins = pinyin_data[byte]
                    is_polyphone = all_pinyins and #all_pinyins > 1
                else
                    py, is_polyphone = get_pinyin_info(byte, settings.multiple)
                end

                insert(result, render_annotated(
                    char, py, settings.markpolyphone, is_polyphone))
            else
                insert(result, char)
            end
        end

        context(concat(result))
    else
        local result = { }
        local i, len = 1, #content

        while i <= len do
            -- 1) Try \xpinyin[py]{chars}
            local m, e, py, chars = content:find("\\xpinyin%s*%[([^%]]*)%]%s*%{([^%}]*)%}", i)

            if m == i then
                local manual_list = { }
                for p in gmatch(py, "[^,%s]+") do
                    insert(manual_list, p)
                end
                local idx = 0
                for char in utf8chars(chars) do
                    local byte = utfbyte(char)
                    if is_hanzi(byte) then
                        idx = idx + 1
                        local mp = manual_list[idx] or manual_list[1]
                        local fp = mp and format_pinyin(mp) or ""
                        local all_pinyins = pinyin_data[byte]
                        local is_polyphone = all_pinyins and #all_pinyins > 1
                        insert(result, render_annotated(
                            char, fp, settings.markpolyphone, is_polyphone))
                    else
                        insert(result, char)
                    end
                end
                i = e + 1
            else
                -- 2) Read one UTF-8 char
                local b = content:byte(i)
                local n = b < 0x80 and 1
                       or b < 0xE0 and 2
                       or b < 0xF0 and 3 or 4
                if i + n - 1 > len then n = 1 end
                local char = sub(content, i, i + n - 1)
                local byte = utfbyte(char)

                if is_hanzi(byte) then
                    local py, is_polyphone = get_pinyin_info(byte, settings.multiple)
                    insert(result, render_annotated(
                        char, py, settings.markpolyphone, is_polyphone))
                else
                    insert(result, char)
                end
                i = i + n
            end
        end

        context(concat(result))
    end
end

-- ---------------------------------------------------------------------------
-- Module registration
-- ---------------------------------------------------------------------------

thirddata            = thirddata or { }
local pinyin         = thirddata.pinyin or { }
thirddata.pinyin     = pinyin

pinyin.setup                = setup
pinyin.set                  = set_pinyin
pinyin.format_pinyin_string = format_pinyin_string
pinyin.process_buffer       = process_buffer

-- Expose data table for potential reload
pinyin._data = pinyin_data

return pinyin