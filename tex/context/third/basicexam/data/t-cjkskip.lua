-- =========================================================
-- 代码来自黄复雄，有细微修改。
-- https://mailman.ntg.nl/archives/list/ntg-context@ntg.nl/thread/CIE43VW6Z4PCMBE2AJZJWFIDTCSLCJ76/#WA7SJQGHHXHWHVA6UAIMVZCHNZLLLL5O
-- newskipkanjiskip.lua
-- 宽度与弹性分离：
--   - insertxkanjiskip 只负责宽度（弹性为 0）
--   - scrp-cjk 的 hanzi method 只负责弹性
-- =========================================================
thirddata = thirddata or {}
thirddata.memos = thirddata.memos or {}
local memos = thirddata.memos

local glyph_id          = nodes.nodecodes.glyph
local glue_id           = nodes.nodecodes.glue
local node_insertbefore = node.insertbefore
local node_new          = node.new
local node_copy         = node.copy
local node_remove       = node.remove
local tex_sp            = tex.sp

-- 常量
local KANJISKIP_SUBTYPE  = 999
local XKANJISKIP_SUBTYPE = 998
local INTERCHAR_SUBTYPE  = 17   -- scrp-cjk 的 intercharacter glue

local subtype_names = {
    [KANJISKIP_SUBTYPE]  = "kanjiskip",
    [XKANJISKIP_SUBTYPE] = "xkanjiskip",
    [INTERCHAR_SUBTYPE]  = "interchar(scrp-cjk)",
}

-- =========================================================
-- 调试开关
-- =========================================================
local debug_pangu = false
local debug_shift = false

function memos.setdebugpangu(flag)
    debug_pangu = flag and true or false
    if debug_pangu then print("[Pangu] debug ON") end
end

function memos.setdebugshift(flag)
    debug_shift = flag and true or false
end

-- =========================================================
-- glue 工厂：弹性强制为 0
-- =========================================================
local kanji_glue_template
local xkanji_glue_template

local lastfont
local kanji_glue, xkanji_glue
local templates_dirty = false 

local function ensure_templates()
    if not kanji_glue_template then
        kanji_glue_template = node_new("glue")
        kanji_glue_template.stretch = 0
        kanji_glue_template.shrink  = 0
        kanji_glue_template.subtype = KANJISKIP_SUBTYPE
    end
    if not xkanji_glue_template then
        xkanji_glue_template = node_new("glue")
        xkanji_glue_template.stretch = 0
        xkanji_glue_template.shrink  = 0
        xkanji_glue_template.subtype = XKANJISKIP_SUBTYPE
    end
end

local function glue_name(g)
    return subtype_names[g.subtype]
        or (nodes.gluecodes and nodes.gluecodes[g.subtype])
        or ("subtype=" .. tostring(g.subtype))
end

local function glue_metrics(g)
    local parts = {}
    if g.width   ~= 0 then parts[#parts+1] = "w=" .. g.width   end
    if g.stretch ~= 0 then parts[#parts+1] = "s=" .. g.stretch end
    if g.shrink  ~= 0 then parts[#parts+1] = "h=" .. g.shrink  end
    return (#parts > 0) and table.concat(parts, " ") or "0"
end

-- =========================================================
-- 字符分类
-- =========================================================
local char_type_cache = {}
local char_shift_cache = {}

local function ischinesechar(c)
    return (c >= 0x04E00 and c <= 0x09FFF)    -- CJK 统一表意文字基本区
        or (c >= 0x03040 and c <= 0x0309F)    -- 平假名
        or (c >= 0x030A0 and c <= 0x030FF)    -- 片假名
        or (c >= 0x0F900 and c <= 0x0FAFF)    -- CJK 兼容表意文字
        or (c >= 0x02E80 and c <= 0x02EFF)    -- CJK 部首补充
        or (c >= 0x02F00 and c <= 0x02FDF)    -- 康熙部首
        or (c >= 0x02FF0 and c <= 0x02FFF)    -- 表意文字描述符
        or  c == 0x03007                      -- 〇（汉字零）
        or (c >= 0x03100 and c <= 0x0312F)    -- 注音符号
        or (c >= 0x03190 and c <= 0x0319F)    -- 汉文训读符号
        or (c >= 0x031A0 and c <= 0x031BF)    -- 注音符号扩展
        or (c >= 0x031C0 and c <= 0x031EF)    -- CJK 笔画
        or (c >= 0x031F0 and c <= 0x031FF)    -- 片假名语音扩展
        or (c >= 0x03200 and c <= 0x032FF)    -- 带圈 CJK 字母及月份
        or (c >= 0x03400 and c <= 0x04DBF)    -- CJK 扩展 A 区
        or (c >= 0x20000 and c <= 0x2A6DF)    -- CJK 扩展 B 区
        or (c >= 0x2A700 and c <= 0x2B73F)    -- CJK 扩展 C 区
        or (c >= 0x2B740 and c <= 0x2B81F)    -- CJK 扩展 D 区
        or (c >= 0x2B820 and c <= 0x2CEAF)    -- CJK 扩展 E 区
        or (c >= 0x2CEB0 and c <= 0x2EBEF)    -- CJK 扩展 F 区
        or (c >= 0x2F800 and c <= 0x2FA1F)    -- CJK 兼容表意文字补充
end

local function ischinesepunctuation(c)
    return (c >= 0x3000 and c <= 0x303F)      -- CJK 符号和标点
        or (c >= 0xFF00 and c <= 0xFFEF)      -- 半角及全角形式
end

local function ispunctuation(c)
    return (c >= 0x0000 and c <= 0x002F)      -- ASCII 控制字符及部分标点
        or (c >= 0x003A and c <= 0x003F)      -- : ; < = > ? @
        or (c >= 0x005B and c <= 0x0060)      -- [ \ ] ^ _ `
        or (c >= 0x007B and c <= 0x007F)      -- { | } ~ DEL
        or (c >= 0x2000 and c <= 0x206F)      -- 通用标点（各种空格、破折号、引号等）
        or ischinesepunctuation(c)            -- 中文标点也视为标点
end

local function isdigit(c)
    return (c >= 0x0030 and c <= 0x0039)      -- ASCII 数字 0-9
        or c == 0x0025
end

-- 西文字母（拉丁字母及扩展）
local function is_latin_letter(c)
    return (c >= 0x41 and c <= 0x5A)       -- A-Z
        or (c >= 0x61 and c <= 0x7A)       -- a-z
        or (c >= 0xC0 and c <= 0x24F)      -- 拉丁扩展 A/B
        or (c >= 0x1E00 and c <= 0x1EFF)   -- 拉丁扩展附加
end

-- 数字（ASCII 0-9）
local function is_pua_digit(c)
    return c >= 0x30 and c <= 0x39
        or (c >= 0xF63A and c <= 0xF641)   -- PUA 映射的 2-9。开启 pnum 之后就被映射到了这里。
        or c == 0xF6DC                     -- PUA 映射的 1  。不知道为什么要这么映射。
end

-- 常见西文标点
local function is_latin_punct(c)
    return (c >= 0x21 and c <= 0x2F)       -- ! " # $ % & ' ( ) * + , - . /
        or (c >= 0x3A and c <= 0x40)       -- : ; < = > ? @
        or (c >= 0x5B and c <= 0x60)       -- [ \ ] ^ _ `
        or (c >= 0x7B and c <= 0x7E)       -- { | } ~
        or c == 0x2018 or c == 0x2019       -- ' '
        or c == 0x201C or c == 0x201D       -- " "
        or c == 0x2013 or c == 0x2014       -- – —
        or c == 0x2026                     -- …
end

-- insert_rules[prev_type][cur_type] 返回 glue 种类名（"kanji"/"xkanji"），未列出者不插入。
-- 与原始 should_insert 语义等价：
--   cjk-cjk      → kanji
--   cjk-digit    → xkanji
--   cjk-other    → xkanji
--   cjk-punct    → 不插入
--   digit-cjk    → xkanji
--   other-cjk    → xkanji
--   punct-cjk    → 不插入
local insert_rules = {
    cjk   = { cjk = "kanji",  digit = "xkanji", other = "xkanji" },
    digit = { cjk = "xkanji" },
    other = { cjk = "xkanji" },
}

-- =========================================================
-- 主过程
-- =========================================================
local quads = fonts.hashes.quads

local function em_to_sp(em, fontid)
    local quad = quads[fontid]
    if not quad then return 0 end
    return math.floor(em * quad + 0.5)
end

function memos.processCJK(head)
    local handler = scripts.handlers and scripts.handlers.hanzi
    local d = handler and handler.datasets and handler.datasets.custom

    local amount   = tex.dimen["ybaselineshift"]
    local do_shift = amount and amount ~= 0
    local do_insert = d ~= nil

    if not do_insert and not do_shift then
        return head, true
    end

    local k_em, x_em = 0, 0
    if do_insert then
        k_em = d.fixed_kanji_width_em  or 0
        x_em = d.fixed_xkanji_width_em or 0
        if debug_pangu then
            print("[Pangu] =====================================")
            print(string.format("[Pangu] process_combined START | k_em=%.4f x_em=%.4f shift=%s",
                k_em, x_em, tostring(do_shift)))
        end
    elseif debug_pangu then
        print("[Pangu] no custom dataset, insert skipped")
    end

    local prev_type, prev_char = nil, nil
    local last_node = nil
    local n = head

    local n_insert, n_skip, n_interchar = 0, 0, 0
    local count_letter, count_digit, count_punct = 0, 0, 0

    while n do
        if debug_pangu and n.id == glue_id and n.subtype == INTERCHAR_SUBTYPE then
            n_interchar = n_interchar + 1
        end

        if n.id == glyph_id then
            local cur_char = n.char

            if do_shift then
                local st = char_shift_cache[cur_char]
                if st == nil then
                    if is_latin_letter(cur_char) then
                        st = "letter"
                    elseif is_pua_digit(cur_char) then
                        st = "digit"
                    elseif is_latin_punct(cur_char) then
                        st = "punct"
                    else
                        st = false
                    end
                    char_shift_cache[cur_char] = st
                end

                if st then
                    n.yoffset = (n.yoffset or 0) + amount
                    if st == "letter" then
                        count_letter = count_letter + 1
                    elseif st == "digit" then
                        count_digit = count_digit + 1
                    elseif st == "punct" then
                        count_punct = count_punct + 1
                    end

                    if debug_shift then
                        print(string.format("SHIFT %s '%s' U+%04X yoffset=%d",
                            st, utf8.char(cur_char), cur_char, n.yoffset))
                    end
                end
            end

            if do_insert then
                local cur_type = char_type_cache[cur_char]
                if not cur_type then
                    if ischinesechar(cur_char) then
                        cur_type = "cjk"
                    elseif isdigit(cur_char) then
                        cur_type = "digit"
                    elseif ispunctuation(cur_char) then
                        cur_type = "punct"
                    else
                        cur_type = "other"
                    end
                    char_type_cache[cur_char] = cur_type
                end

                -- 关键：只在 CJK glyph 上刷新参考 quad，参考 quad 以 CJK 字体为准
                -- 段落开头是西文时用 lastfont == nil 兜底刷新一次。
                if cur_type == "cjk" or not lastfont then
                    local f = n.font
                    -- 内部逻辑完全等价于原 refresh_templates(f)
                    if not (f == lastfont and not templates_dirty) then
                        lastfont = f
                        templates_dirty = false  
                        ensure_templates()

                        if k_em ~= 0 then
                            kanji_glue_template.width = em_to_sp(k_em, f)
                            kanji_glue = kanji_glue_template
                        else
                            kanji_glue = nil
                        end

                        if x_em ~= 0 then
                            xkanji_glue_template.width = em_to_sp(x_em, f)
                            xkanji_glue = xkanji_glue_template
                        else
                            xkanji_glue = nil
                        end

                        if debug_pangu then
                            print(string.format("[Pangu] ref-font=%s quad=%d | kanji_w=%s xkanji_w=%s",
                                tostring(f), quads[f] or -1,
                                kanji_glue  and kanji_glue.width  or -1,
                                xkanji_glue and xkanji_glue.width or -1))
                        end
                    end
                end

                if prev_type then
                    local rule = insert_rules[prev_type]
                    local glue_kind = rule and rule[cur_type] or nil
                    if glue_kind then
                        local glue_template =
                            (glue_kind == "kanji")  and kanji_glue  or
                            (glue_kind == "xkanji") and xkanji_glue or nil
                        -- =========================================================
                        -- 与已有 glue 协商
                        --   subtype 17 (scrp-cjk 弹性 glue) → 保护它，插自己的宽度 glue
                        --   其他 glue → 只比较宽度
                        -- =========================================================
                        if glue_template then
                            -- 1. 决策阶段
                            local should_insert = true
                            local action = "INSERT" -- 默认直接插

                            if last_node and last_node.id == glue_id then
                                if last_node.subtype == INTERCHAR_SUBTYPE then
                                    action = "KEEP" -- 保护 scrp-cjk 弹性胶
                                elseif last_node.width >= glue_template.width then
                                    should_insert = false
                                    action = "SKIP"
                                else
                                    action = "REPLACE"
                                    head = node_remove(head, last_node)
                                end
                            end

                            -- 2. 执行阶段
                            if should_insert then
                                local glue = node_copy(glue_template)
                                head = node_insertbefore(head, n, glue)
                                n_insert = n_insert + 1
                            else
                                n_skip = n_skip + 1
                            end

                            -- 3. 唯一的 debug 打印点
                            if debug_pangu then
                                local old_desc = (last_node and last_node.id == glue_id)
                                                 and (glue_name(last_node) .. " (" .. glue_metrics(last_node) .. ")")
                                                 or "-"
                                local new_desc = should_insert
                                                 and (glue_name(glue_template) .. " (" .. glue_metrics(glue_template) .. ")")
                                                 or "-"
                                print(string.format(
                                    "[Pangu] %-7s | old=%-28s | new=%-28s | '%s'(U+%04X) -> '%s'(U+%04X)",
                                    action, old_desc, new_desc,
                                    utf8.char(prev_char), prev_char,
                                    utf8.char(cur_char), cur_char))
                            end
                        end
                    end
                end

                prev_type, prev_char = cur_type, cur_char
          end
        end

        last_node = n
        n = n.next
    end

    if debug_pangu then
        print(string.format(
            "[Pangu] process_combined END | inserted=%d skipped=%d | interchar_seen=%d",
            n_insert, n_skip, n_interchar))
        print("[Pangu] =====================================")
    end
    if debug_shift then
        print(string.format("SHIFT SUMMARY: letters=%d digits=%d puncts=%d amount=%d sp",
            count_letter, count_digit, count_punct, amount or 0))
    end

    return head, true
end

-- =========================================================
--   第一路：弹性 → scripts.handlers.hanzi.datasets.custom 字段
--   第二路：宽度 → tex.setglue("kanjiskip"/"xkanjiskip")
-- =========================================================
local dataset_keys = {
    shrink         = "inter_char_shrink_factor",
    stretch        = "inter_char_stretch_factor",
    halfshrink     = "inter_char_half_shrink_factor",
    halfstretch    = "inter_char_half_stretch_factor",
    quartershrink  = "inter_char_quarter_shrink_factor",
    quarterstretch = "inter_char_quarter_stretch_factor",
    hangulpenalty  = "inter_char_hangul_penalty",
}

function memos.setdataset(method, name, kv)
    if debug_pangu then
        print(string.format("[Pangu] setdataset method=%s name=%s", method, name))
    end

    local handler = scripts.handlers and scripts.handlers[method]
    if not handler then
        logs.report("pangu", "method not found: %s", method)
        return
    end
    local d = handler.datasets and handler.datasets[name]
    if not d then
        logs.report("pangu", "dataset not found: %s/%s", method, name)
        return
    end

    -- 弹性：写 dataset 字段（不变）
    for short, value in next, kv do
        local field = dataset_keys[short]
        if field then
            d[field] = tonumber(value)
            if debug_pangu then
                print(string.format("[Pangu]   dataset[%s] = %s", field, tostring(value)))
            end
        end
    end

    -- 宽度：只存 em 值，不调 tex.setglue
    if kv.width ~= nil then
        d.fixed_kanji_width_em = tonumber(kv.width)
        templates_dirty = true
        if debug_pangu then
            print(string.format("[Pangu]   fixed_kanji_width_em = %s", tostring(kv.width)))
        end
    end
    if kv.halfwidth ~= nil then
        d.fixed_xkanji_width_em = tonumber(kv.halfwidth)
        templates_dirty = true 
        if debug_pangu then
            print(string.format("[Pangu]   fixed_xkanji_width_em = %s", tostring(kv.halfwidth)))
        end
    end
end

-- =========================================================
-- 节点流调试
-- =========================================================
local my_glue_names = {
    [KANJISKIP_SUBTYPE]  = "kanjiskip",
    [XKANJISKIP_SUBTYPE] = "xkanjiskip",
    [INTERCHAR_SUBTYPE]  = "interchar",
}

local function debug_glue_name(n)
    return my_glue_names[n.subtype]
        or (nodes.gluecodes and nodes.gluecodes[n.subtype])
        or ("subtype=" .. tostring(n.subtype))
end

local function short(n)
    local id = n.id
    if id == node.id"glyph" then
        if n.components then
            local s = {}
            for comp in node.traverse(n.components) do
                if comp.id == node.id"glyph" then
                    s[#s+1] = utf.char(comp.char)
                end
            end
            return "【" .. table.concat(s) .. "】"
        end
        return "【" .. (utf.char(n.char) or "?") .. "】"
    elseif id == node.id"glue" then
        local gc = debug_glue_name(n) or "?"
        local parts = {}
        if n.width   ~= 0 then parts[#parts+1] = "w=" .. n.width   end
        if n.stretch ~= 0 then parts[#parts+1] = "s=" .. n.stretch end
        if n.shrink  ~= 0 then parts[#parts+1] = "h=" .. n.shrink  end
        local metrics = (#parts > 0) and table.concat(parts, " ") or "0"
        return "<" .. gc .. " " .. metrics .. ">"
    elseif id == node.id"kern" then
        return "<kern " .. n.kern .. ">"
    elseif id == node.id"penalty" then
        return "<pen " .. tostring(n.penalty or 0) .. ">"
    elseif id == node.id"disc" then
        return "<disc>"
    elseif id == node.id"local_par" then
        return "<par>"
    elseif id == node.id"hlist" then
        return "<hlist>"
    elseif id == node.id"vlist" then
        return "<vlist>"
    elseif id == node.id"whatsit" then
        return "<whatsit>"
    elseif id == node.id"boundary" then
        return "<boundary>"
    elseif id == node.id"dir" then
        return "<dir>"
    elseif id == node.id"adjust" then
        return "<adjust>"
    else
        return "<id=" .. tostring(id) .. ">"
    end
end

local function dump(list, indent)
    indent = indent or ""
    local out = {}
    for n in node.traverse(list) do
        out[#out+1] = short(n)
    end
    print(indent .. table.concat(out, " "))
end

function memos.debugglues(head)
    print("========== NODE STREAM ==========")
    for n in node.traverse(head) do
        if n.id == node.id"hlist" then
            print("--- hlist ---")
            if n.head then dump(n.head, "  ") end
        elseif n.id == node.id"vlist" then
            print("--- vlist ---")
            if n.head then dump(n.head, "  ") end
        else
            print("  " .. short(n))
        end
    end
    print("=================================")
    return head
end

function memos.enablegluedebug()
    nodes.tasks.appendaction("finalizers", "after", "thirddata.memos.debugglues")
end

function memos.disablegluedebug()
    nodes.tasks.disableaction("finalizers", "after", "thirddata.memos.debugglues")
end

-- =========================================================
-- 主任务开关
-- =========================================================
function memos.disablepangu()
    nodes.tasks.disableaction("processors", "after", "thirddata.memos.processCJK")
end

function memos.enablepangu()
    nodes.tasks.enableaction("processors", "after", "thirddata.memos.processCJK")
end

-- =========================================================
-- 注册（只注册一次）
--   ⚠️ 关键：processCJK 必须放在 processors 的 after 阶段
--      scrp-cjk 的 injector 在 before 阶段运行，先插 subtype 17
-- =========================================================
if not memos._registered then
    nodes.tasks.appendaction("processors", "after", "thirddata.memos.processCJK")
    memos._registered = true
end