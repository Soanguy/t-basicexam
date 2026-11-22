thirddata                            = thirddata or {}
thirddata.zhpunc                     = thirddata.zhpunc or {}
thirddata.zhpunc.enabled             = true
thirddata.zhpunc.debug               = false
thirddata.zhpunc.hangjian            = false
thirddata.zhpunc.model               = thirddata.zhpunc.model or "kaiming"   -- 默认开明
thirddata.zhpunc.space_quad          = thirddata.zhpunc.space_quad or 0.5
thirddata.zhpunc.hangjian_shift      = thirddata.zhpunc.hangjian_shift or 0.4
thirddata.zhpunc.debug_pangu         = thirddata.zhpunc.debug_pangu or false
thirddata.zhpunc.debug_shift         = thirddata.zhpunc.debug_shift or false
thirddata.vtypeset                   = thirddata.vtypeset or {}
thirddata.vtypeset.appended          = thirddata.vtypeset.appended or false

function thirddata.zhpunc.setdebugpangu(flag)
    thirddata.zhpunc.debug_pangu = flag and true or false
    if thirddata.zhpunc.debug_pangu then print("[Pangu] debug ON") end
end

function thirddata.zhpunc.setdebugshift(flag)
    thirddata.zhpunc.debug_shift = flag and true or false
    if thirddata.zhpunc.debug_shift then print("[Shift] debug ON") end
end

-- 用户扩展符号类别存储
thirddata.zhpunc.user_classes        = {}  -- 用户定义的类别
thirddata.zhpunc.user_char_class     = {}  -- 用户定义的符号类别映射：{char=class_name}
thirddata.zhpunc.user_hangjian       = {}  -- 用户定义的行间标点：{char=true}
thirddata.zhpunc.user_rotate         = {}  -- 用户定义的旋转标点：{char=true}
thirddata.zhpunc.user_protrude_left  = {}  -- 用户定义的行首凸排符号：{char=true}
thirddata.zhpunc.user_protrude_right = {}  -- 用户定义的行尾凸排符号：{char=true}
thirddata.zhpunc.user_forbid_start   = {}  -- 用户定义的行首禁排符号：{char=true}
thirddata.zhpunc.user_forbid_end     = {}  -- 用户定义的行尾禁排符号：{char=true}
thirddata.zhpunc.user_quad           = {}  -- 用户定义的占位角数：{char=1/0.5/2}
thirddata.zhpunc.user_space          = {}  -- 用户定义的前、后加空角数：{char={before=,after=}}

local zhpunc = thirddata.zhpunc
local user_space_ref      = zhpunc.user_space
local user_quad_ref       = zhpunc.user_quad
local user_char_class     = zhpunc.user_char_class
local user_hangjian       = zhpunc.user_hangjian
local user_rotate         = zhpunc.user_rotate
local user_protrude_left  = zhpunc.user_protrude_left
local user_protrude_right = zhpunc.user_protrude_right
local user_forbid_start   = zhpunc.user_forbid_start
local user_forbid_end     = zhpunc.user_forbid_end

local _

-- 标点模式配置，默认全角
local quanjiao, kaiming, banjiao, yuanyang = "quanjiao", "kaiming", "banjiao","yuanyang"

local hlist_id   = nodes.nodecodes.hlist
local vlist_id   = nodes.nodecodes.vlist
local penalty_id = nodes.nodecodes.penalty
local rule_id    = nodes.nodecodes.rule
local glyph_id   = nodes.nodecodes.glyph --node.id ('glyph')
local glue_id    = nodes.nodecodes.glue
local kern_id    = nodes.nodecodes.kern

local node_traverse     = node.traverse
local node_tail         = node.tail
local node_hpack        = node.hpack
local node_insertbefore = node.insertbefore
local node_insertafter  = node.insertafter
local nodes_pool_kern   = nodes.pool.kern
local node_new          = node.new
local node_copy         = node.copy
local node_copylist     = node.copylist
local node_remove       = node.remove
local node_free         = node.free

local nodes_tasks_appendaction = nodes.tasks.appendaction

-- =========================================================
-- 字体与盘古配置
-- =========================================================
local fonthashes = fonts.hashes
local fontdata   = fonthashes.identifiers --字体身份表
local quads      = fonts.hashes.quads

-- 插入规则表：[prev_type][cur_type] → glue 类型
-- 分类只有三态：cjk（汉字）、other（西文/数字）、punct（标点）
--   cjk   - cjk   → kanji   汉字之间（k_em = 0 时实际不插）
--   cjk   - other → xkanji  汉字与西文/数字之间（盘古之白）
--   other - cjk   → xkanji  西文/数字与汉字之间（盘古之白）
--   *     - punct → false   标点边界不插，归 zhpunc
--   punct - *     → false   标点边界不插，归 zhpunc
local TYPE_NONE  = 0   -- 结构性哨兵（字体切换标记 char=0 等），不参与分类
local TYPE_CJK   = 1
local TYPE_OTHER = 2
local TYPE_PUNCT = 3

local KANJISKIP_SUBTYPE  = 999
local XKANJISKIP_SUBTYPE = 998
local INTERCHAR_SUBTYPE  = 17  -- scrp-cjk 的 intercharacter glue

local insert_rules = {
    [TYPE_CJK]   = { [TYPE_CJK] = "kanji",  [TYPE_OTHER] = "xkanji", [TYPE_PUNCT] = false },
    [TYPE_OTHER] = { [TYPE_CJK] = "xkanji", [TYPE_PUNCT] = false },
    [TYPE_PUNCT] = { [TYPE_PUNCT] = false },
}

local kanji_glue_template, xkanji_glue_template
local lastfont, kanji_glue, xkanji_glue, templates_dirty = false

-- 标点缓存数据
-- 改进：使用字体名称+字号作为key，避免font ID动态变化导致的缓存无限增长
-- 结构：{cache_key={char={l_kern=, r_kern=, one_side_space=}}, quad=}
thirddata.zhpunc.puncs_font = {}

-- 获取符号的类别（优先用户定义，其次默认）
-- 检查符号是否为行间标点（优先用户定义）
-- 检查符号是否需要旋转（优先用户定义）
-- 检查符号是否需要行首凸排（优先用户定义）
-- 检查符号是否需要行尾凸排（优先用户定义）
-- 检查符号是否行首禁排（优先用户定义）
-- 检查符号是否行尾禁排（优先用户定义）
-- 字符级类别缓存：char -> 类别名 | false（false 表示"无类别"）
-- 所有修改 user_char_class 的接口都调用 clear_punc_cache()
-- font_id_to_key: font_id → cache_key 直查缓存；字体注册后参数不变，可安全长期缓存
local char_type_cache  = {}
local char_shift_cache = {} 
local char_class_cache = {}
local is_punc_cache_h  = {} -- 字符级 is_punc 结果缓存：char -> 1 | 2 | false
local is_punc_cache_v  = {} -- 水平/竖直分开，避免 vtypeset.appended 切换时需清缓存
local font_id_to_key   = {} 

-- 标点分类
local puncs_left_sign     = 'puncs_left_sign'     -- 左半标号，如《
local puncs_right_sign    = 'puncs_right_sign'    -- 右半标号，如》
local puncs_repeat_sign   = 'puncs_repeat_sign'
local puncs_dakuten       = 'puncs_dakuten'
local puncs_inner_point   = 'puncs_inner_point'   -- 句内点号，如、
local puncs_ending_point  = 'puncs_ending_point'  -- 句末点号，如。
local puncs_ellipsis      = 'puncs_ellipsis'      -- 省略号…
local puncs_dash          = 'puncs_dash'          -- 破折号—
local puncs_full_junction = 'puncs_full_junction' -- 全角连接号～
local puncs_long_vowel    = 'puncs_full_junction'
local puncs_half_junction = 'puncs_half_junction' -- 半角连接号，如-
local puncs_no            = 'puncs_no'            -- 非标点的可视结点

-- 所有标点
local puncs = {
    -- 左半标号
    [0x2018] = puncs_left_sign, -- ‘
    [0x201C] = puncs_left_sign, -- “
    [0x3008] = puncs_left_sign, -- 〈
    [0x300A] = puncs_left_sign, -- 《
    [0x3010] = puncs_left_sign, -- 【
    [0x3014] = puncs_left_sign, -- 〔
    [0xFF08] = puncs_left_sign, -- （
    [0xFF3B] = puncs_left_sign, -- ［
    -- ext
    [0x300C] = puncs_left_sign, -- 「
    [0x300E] = puncs_left_sign, -- 『
    [0x3016] = puncs_left_sign, -- 〖
    [0xFF5B] = puncs_left_sign, -- ｛

    -- 补：左半标号
    [0x3018] = puncs_left_sign, -- 〘  [补 全角宽]
    [0x301A] = puncs_left_sign, -- 〚  [补 全角宽]
    [0x301D] = puncs_left_sign, -- 〝  [补 全角宽]
--  [0xFF62] = puncs_left_sign, -- ｢  [补 半角]
--  [0xFF5F] = puncs_left_sign, -- ｟  [补 全角]
--  [0x00AB] = puncs_left_sign, -- «  [补 非全半]
--  [0x2039] = puncs_left_sign, -- ‹  [补 非全半]
--  [0xFE17] = puncs_left_sign, -- ︗  [补 全角宽]
--  [0xFE35] = puncs_left_sign, -- ︵  [补 全角宽]
--  [0xFE37] = puncs_left_sign, -- ︷  [补 全角宽]
--  [0xFE39] = puncs_left_sign, -- ︹  [补 全角宽]
--  [0xFE3B] = puncs_left_sign, -- ︻  [补 全角宽]
--  [0xFE3D] = puncs_left_sign, -- ︽  [补 全角宽]
--  [0xFE3F] = puncs_left_sign, -- ︿  [补 全角宽]
--  [0xFE41] = puncs_left_sign, -- ﹁  [补 全角宽]
--  [0xFE43] = puncs_left_sign, -- ﹃  [补 全角宽]

    -- 右半标号
    [0x2019] = puncs_right_sign, -- ’
    [0x201D] = puncs_right_sign, -- ”
    [0x3009] = puncs_right_sign, -- 〉
    [0x300B] = puncs_right_sign, -- 》
    [0x3011] = puncs_right_sign, -- 】
    [0x3015] = puncs_right_sign, -- 〕
    [0xFF09] = puncs_right_sign, -- ）
    [0xFF3D] = puncs_right_sign, -- ］
    -- ext
    [0x300D] = puncs_right_sign, -- 」
    [0x300F] = puncs_right_sign, -- 』
    [0x3017] = puncs_right_sign, -- 〗
    [0xFF5D] = puncs_right_sign, -- ｝

    -- 补：右半标号
    [0x3019] = puncs_right_sign, -- 〙  [补 全角宽]
    [0x301B] = puncs_right_sign, -- 〛  [补 全角宽]
    [0x301E] = puncs_right_sign, -- 〞  [补 全角宽]
    [0x301F] = puncs_right_sign, -- 〟  [补 全角宽]
--  [0xFF63] = puncs_right_sign, -- ｣  [补 半角]
--  [0xFF60] = puncs_right_sign, -- ｠  [补 全角]
--  [0x00BB] = puncs_right_sign, -- »  [补 非全半]
--  [0x203A] = puncs_right_sign, -- ›  [补 非全半]
--  [0xFE18] = puncs_right_sign, -- ︘  [补 全角宽]
--  [0xFE36] = puncs_right_sign, -- ︶  [补 全角宽]
--  [0xFE38] = puncs_right_sign, -- ︸  [补 全角宽]
--  [0xFE3A] = puncs_right_sign, -- ︺  [补 全角宽]
--  [0xFE3C] = puncs_right_sign, -- ︼  [补 全角宽]
--  [0xFE3E] = puncs_right_sign, -- ︾  [补 全角宽]
--  [0xFE40] = puncs_right_sign, -- ﹀  [补 全角宽]
--  [0xFE42] = puncs_right_sign, -- ﹂  [补 全角宽]
--  [0xFE44] = puncs_right_sign, -- ﹄  [补 全角宽]

    -- 句内点号
    [0x3001] = puncs_inner_point,   -- 、
    [0xFF0C] = puncs_inner_point,   -- ，
    [0xFF1A] = puncs_inner_point,   -- ：
    [0xFF1B] = puncs_inner_point,   -- ；
    -- 补
    [0xFE10] = puncs_inner_point,   -- ︐  [补 全角宽]
    [0xFE11] = puncs_inner_point,   -- ︑  [补 全角宽]
    [0xFE13] = puncs_inner_point,   -- ︓  [补 全角宽]
    [0xFE14] = puncs_inner_point,   -- ︔  [补 全角宽]

    -- 句末点号
    [0xFF01] = puncs_ending_point,   -- ！
    [0xFF1F] = puncs_ending_point,   -- ？
    [0x3002] = puncs_ending_point,   -- 。
    -- ext
    [0xFF0E] = puncs_ending_point,   -- ．
    -- 补
--  [0xFE12] = puncs_ending_point,   -- ︒  [补 全角宽]
--  [0xFE15] = puncs_ending_point,   -- ︕  [补 全角宽]
--  [0xFE16] = puncs_ending_point,   -- ︖  [补 全角宽]
    [0x203C] = puncs_ending_point,   -- ‼  [补 全角宽]
    [0x2047] = puncs_ending_point,   -- ⁇  [补 全角宽]
    [0x2048] = puncs_ending_point,   -- ⁈  [补 全角宽]
    [0x2049] = puncs_ending_point,   -- ⁉  [补 全角宽]

    -- 省略号
    [0x2026] = puncs_ellipsis, -- …
--  [0x2025] = puncs_ellipsis, -- ‥  [补 全角宽]
--  [0xFE19] = puncs_ellipsis, -- ︙  [补 全角宽]
--  [0x22EF] = puncs_ellipsis, -- ⋯  [补 非全半]
--  [0x22EE] = puncs_ellipsis, -- ⋮  [补 非全半]
--  [0x22F1] = puncs_ellipsis, -- ⋱  [补 非全半]

    -- 破折号
    [0x2014] = puncs_dash, -- — 一字线，兼puncs_full_junction
    [0x2015] = puncs_dash, -- ―  [补 全角宽]
    [0x2500] = puncs_dash, -- ─  [补 非全半]
    [0xFE31] = puncs_dash, -- ︱  [补 全角宽]
    [0xFE32] = puncs_dash, -- ︲  [补 全角宽]
--  [0x2010] = puncs_dash, -- ‐  [补 非全半]
--  [0x2011] = puncs_dash, -- ‑  [补 非全半]
--  [0x2013] = puncs_dash, -- –  [补 非全半]
--  [0x2212] = puncs_dash, -- −  [补 非全半]
    [0xFF0D] = puncs_dash, -- －  [补 全角]

    -- 全角连接号
    [0xff5e] = puncs_full_junction, -- ～ 一字线
    [0x301C] = puncs_full_junction, -- 〜  [补 全角宽]
    [0x3030] = puncs_full_junction, -- 〰  [补 全角宽]
    [0x30FC] = puncs_long_vowel,    -- ー  [补 全角宽]
--  [0xFF70] = puncs_long_vowel,    -- ｰ  [补 半角]
    [0x30A0] = puncs_full_junction, -- ゠  [补 全角宽]

    -- 半角连接号
--  [0x00b7] = puncs_half_junction, -- ·   MIDDLE DOT
--  不处理半角字符
--  [0x002D] = puncs_half_junction, -- -   Hyphen-Minus. Will there be any side effects?
--  [0x002F] = puncs_half_junction, -- /   Solidus
    [0xff0f] = puncs_half_junction, -- ／   Solidus
    [0x30FB] = puncs_inner_point, -- ・  [补 全角宽]
--  [0xFF65] = puncs_inner_point, -- ･  [补 半角]
--  [0x00B7] = puncs_inner_point, -- ·  [补 半角]
--  [0x2027] = puncs_inner_point, -- ‧  [补 非全半]

    -- 补：重复符号 / 叠字 / 浊点（行頭禁则）
    [0x3005] = puncs_repeat_sign, -- 々  [补 全角宽]
    [0x3006] = puncs_repeat_sign, -- 〆  [补 全角宽]
    [0x303B] = puncs_repeat_sign, -- 〻  [补 全角宽]
    [0x309D] = puncs_repeat_sign, -- ゝ  [补 全角宽]
    [0x309E] = puncs_repeat_sign, -- ゞ  [补 全角宽]
    [0x30FD] = puncs_repeat_sign, -- ヽ  [补 全角宽]
    [0x30FE] = puncs_repeat_sign, -- ヾ  [补 全角宽]
    [0x309B] = puncs_dakuten,     -- ゛  [补 全角宽]
    [0x309C] = puncs_dakuten,     -- ゜  [补 全角宽]
--  [0xFF9E] = puncs_dakuten,     -- ﾞ  [补 半角]
--  [0xFF9F] = puncs_dakuten,     -- ﾟ  [补 半角]
--  [0x3099] = puncs_dakuten,     -- 组合浊点  [补 组合]
--  [0x309A] = puncs_dakuten,     -- 组合半浊点  [补 组合]
 
    -- 补：半角 / 竖排兼容标点
--  [0xFF61] = puncs_ending_point, -- ｡  [补 半角]
--  [0xFF64] = puncs_inner_point,  -- ､  [补 半角]
    --  注意 0xFF65 已作为中点 0xFF70 已作为长音 0xFF62 / 0xFF63 / 0xFF5F / 0xFF60 已加

    -- 补：其他可能需要的全角符号
    [0xFF3C] = puncs_half_junction, -- ＼  [补 全角]
    [0xFF5C] = puncs_half_junction, -- ｜  [补 全角]
}

-- 加空的组合与数量
local inserting_space = {
    -- 开明
    [kaiming] = {
        [puncs_ending_point] =   {puncs_left_sign = 1,  --。《
                                  puncs_no        = 1}, --。囗
    },
    -- 全角
    [quanjiao] = {
        [puncs_no]           =   {puncs_left_sign = 1}, --囗《
        [puncs_right_sign]   =   {puncs_left_sign = 1,  --》《
                                  puncs_no        = 1}, --》囗
        [puncs_inner_point]  =   {puncs_left_sign = 1,  --、《
                                  puncs_no        = 1}, --、囗
        [puncs_ending_point] =   {puncs_left_sign = 1,  --。《
                                  puncs_no        = 1}, --。囗
    },
}

-- 竖排时要旋转的标点/竖排标点（装在hlist中）
local puncs_to_rotate = {
    [0x3001] = true,   -- 、
    [0xFF0C] = true,   -- ，
    [0x3002] = true,   -- 。
    [0xFF0E] = true,   -- ．
    [0xFF1A] = true,   -- ：
    -- 以下，后两位压缩值与前两位相乘后相等，即与竖排模块的“居中”一致
    [0xFF01] = true,   -- ！
    [0xFF1B] = true,   -- ；
    [0xFF1F] = true,   -- ？
}

-- 行间符号
local puncs_to_hangjian = {
    [0x3001] = true,   -- 、
    [0xFF0C] = true,   -- ，
    [0x3002] = true,   -- 。
    [0xFF0E] = true,   -- ．
    [0xFF1A] = true,   -- ：

    [0xFF01] = true,   -- ！
    [0xFF1B] = true,   -- ；
    [0xFF1F] = true,   -- ？

    -- [0x2018] = true,  -- ‘
    -- [0x2019] = true,  -- ’
    -- [0x201C] = true,  -- “
    -- [0x201D] = true,  -- ”
}

-- 全角标点
local full_quad_puncs = {
    [0x2026] = true, -- …
    [0x2014] = true, -- — 半字线，兼puncs_full_junction
    [0xff5e] = true, -- ～ 半字线
    [0xff0f] = true, -- ／   Solidus
}

-- 竖排全角标点
local v_full_quad_puncs = {
    [0xFF01] = true,   -- ！
    [0xFF1B] = true,   -- ；
    [0xFF1F] = true,   -- ？
}

-- 短类别名 → 完整类别名映射（供 add_to_class 与 setup_chars 共用）
local puncs_class_map = {
    left     = puncs_left_sign,
    right    = puncs_right_sign,
    inner    = puncs_inner_point,
    ending   = puncs_ending_point,
    ellipsis = puncs_ellipsis,
    dash     = puncs_dash,
    full     = puncs_full_junction,
    half     = puncs_half_junction,
}

-- 行尾可凸排/压缩的默认类别：
--   右标号（》」））、句内点号（、，：；）、句末点号（。！？）、省略号（…）
local protrude_right_classes = {
    [puncs_right_sign]   = true,
    [puncs_inner_point]  = true,
    [puncs_ending_point] = true,
    [puncs_ellipsis]     = true,
}

-- 缓存统计
thirddata.zhpunc._cache_stats = {
    access_count = 0,
    last_cleanup = 0,
    interval = 10000   -- 每 10000 次访问清理一次，可配置
}

-- =========================================================
-- 基础工具函数
-- =========================================================
-- 释放整条结点列表（含每个结点的内部子列表）
local function node_flush_list(head)
    while head do
        local next_n = head.next
        local sub = head.list
        if sub then node_flush_list(sub) end
        node_free(head)
        head = next_n
    end
end

-- 解析字符串中的 Unicode 字符，返回码点数组
local function parse_chars(str)
    local chars = {}
    for _, code in utf8.codes(str) do
        table.insert(chars, code)
    end
    return chars
end

-- 把参数值解析为布尔（兼容 yes/no/on/off/true/false/1/0，以及字面 true/false）
local function bool_val(val)
    if type(val) == "string" then
        local v = val:lower()
        if v=="yes" or v=="true" or v=="on" or v=="t" or v=="1" then return true end
        if v=="no" or v=="false" or v=="off" or v=="f" or v=="0" then return false end
        return false
    end
    return val == true
end

-- 三态布尔：nil 表示"用户未设置"；否则按 bool_val 解析
local function opt_bool(val)
    if val == nil then return nil end
    return bool_val(val)
end

local subtype_names = {
    [KANJISKIP_SUBTYPE]  = "kanjiskip",
    [XKANJISKIP_SUBTYPE] = "xkanjiskip",
    [INTERCHAR_SUBTYPE]  = "interchar(scrp-cjk)",
}

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

-- 节点流调试工具
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
                if comp.id == node.id"glyph" then s[#s+1] = utf.char(comp.char) end
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
    elseif id == node.id"kern" then return "<kern " .. n.kern .. ">"
    elseif id == node.id"penalty" then return "<pen " .. tostring(n.penalty or 0) .. ">"
    elseif id == node.id"disc" then return "<disc>"
    elseif id == node.id"local_par" then return "<par>"
    elseif id == node.id"hlist" then return "<hlist>"
    elseif id == node.id"vlist" then return "<vlist>"
    elseif id == node.id"whatsit" then return "<whatsit>"
    elseif id == node.id"boundary" then return "<boundary>"
    elseif id == node.id"dir" then return "<dir>"
    elseif id == node.id"adjust" then return "<adjust>"
    else return "<id=" .. tostring(id) .. ">" end
end

local function dump(list, indent)
    indent = indent or ""
    local out = {}
    for n in node.traverse(list) do out[#out+1] = short(n) end
    print(indent .. table.concat(out, " "))
end

local function resolve_class(raw)
    return puncs_class_map[raw] or raw
end

-- 获取字体的稳定缓存key（字体名称+字号）
-- 避免因font ID动态变化导致缓存无限增长
local function get_font_cache_key(font_id)
    local cached = font_id_to_key[font_id]
    if cached then return cached end

    local fdata = fontdata[font_id]
    if not fdata then
        -- fdata 未就绪时不做缓存，等字体注册完成后再生成正式 key
        return tostring(font_id)
    end

    local fontname = fdata.name or fdata.fontname or fdata.fullname or fdata.psname
    if not fontname then
        fontname = fdata.filename or tostring(font_id)
    end

    local size = fdata.parameters and fdata.parameters.quad or 655360
    -- quad 以 sp（scaled point）计，1pt = 65536sp。
    -- 转成"0.1pt"为单位的整数（12pt → 120）作为 key，避免浮点、保证同字号共享。
    local sp_per_tenth_pt = 6553.6       -- 65536 / 10
    local size_tenth_pt = math.floor(size / sp_per_tenth_pt + 0.5)

    local key = string.format("%s@%d", fontname, size_tenth_pt)
    font_id_to_key[font_id] = key
    return key
end

local function em_to_sp(em, fontid)
    local quad = quads[fontid]
    if not quad then return 0 end
    return math.floor(em * quad + 0.5)
end

local function refresh_templates(f, cfg)
    if not f then return end
    if f == lastfont and not templates_dirty then return end
    lastfont = f
    templates_dirty = false

    -- 懒初始化（原 ensure_templates 内容）
    if not kanji_glue_template then
        kanji_glue_template = node_new("glue")
        kanji_glue_template.subtype = KANJISKIP_SUBTYPE
    end
    if not xkanji_glue_template then
        xkanji_glue_template = node_new("glue")
        xkanji_glue_template.subtype = XKANJISKIP_SUBTYPE
    end

    local k, x = cfg.k, cfg.x
    if k.width ~= 0 then
        kanji_glue_template.width   = em_to_sp(k.width,   f)
        kanji_glue_template.stretch = em_to_sp(k.stretch, f)
        kanji_glue_template.shrink  = em_to_sp(k.shrink,  f)
        kanji_glue = kanji_glue_template
    else
        kanji_glue = nil
    end
    if x.width ~= 0 then
        xkanji_glue_template.width   = em_to_sp(x.width,   f)
        xkanji_glue_template.stretch = em_to_sp(x.stretch, f)
        xkanji_glue_template.shrink  = em_to_sp(x.shrink,  f)
        xkanji_glue = xkanji_glue_template
    else
        xkanji_glue = nil
    end

    if thirddata.zhpunc.debug_pangu then
        print(string.format(
            "[Pangu] ref-font=%s quad=%d | k=%d/%d/%d x=%d/%d/%d",
            tostring(f), quads[f] or -1,
            kanji_glue  and kanji_glue_template.width   or -1,
            kanji_glue  and kanji_glue_template.stretch or -1,
            kanji_glue  and kanji_glue_template.shrink  or -1,
            xkanji_glue and xkanji_glue_template.width   or -1,
            xkanji_glue and xkanji_glue_template.stretch or -1,
            xkanji_glue and xkanji_glue_template.shrink  or -1))
    end
end

local function is_chinesechar(c)
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

-- shift 分类（ybaselineshift 用，和插胶完全无关）
-- 返回 "letter" / "digit" / "punct" / false
-- 三类行为相同：都是 n.yoffset += amount，返回值只用于 debug 标签和统计。
--
-- 判断顺序：letter → digit → punct。ASCII 数字（0x30–0x39）不在 letter 范围内，
-- ASCII 标点（0x21–0x2F 等）也不和 letter/digit 重叠，所以顺序不影响正确性，
-- 只是按“字母最常见、数字次之、标点最后”排，读起来顺。
local function is_shift_class(c)
    -- 西文字母：A-Z、a-z、拉丁扩展 A/B、拉丁扩展附加
    if (c >= 0x41 and c <= 0x5A)
        or (c >= 0x61 and c <= 0x7A)
        or (c >= 0xC0 and c <= 0x24F)
        or (c >= 0x1E00 and c <= 0x1EFF) then
        return "letter"
    end

    -- 数字：ASCII 0-9，外加 PUA 映射（pnum 开启后数字映射到 PUA）
    if (c >= 0x30 and c <= 0x39)
        or (c >= 0xF63A and c <= 0xF641)   -- PUA 映射的 2-9
        or c == 0xF6DC then                -- PUA 映射的 1
        return "digit"
    end

    -- 常见西文标点：ASCII 标点区间 + 弯引号、破折号、省略号
    if (c >= 0x21 and c <= 0x2F)           -- ! " # $ % & ' ( ) * + , - . /
        or (c >= 0x3A and c <= 0x40)       -- : ; < = > ? @
        or (c >= 0x5B and c <= 0x60)       -- [ \ ] ^ _ `
        or (c >= 0x7B and c <= 0x7E)       -- { | } ~
        or c == 0x2018 or c == 0x2019       -- ‘ ’
        or c == 0x201C or c == 0x201D       -- “ ”
        or c == 0x2013 or c == 0x2014       -- – —
        or c == 0x2026 then                -- …
        return "punct"
    end

    return false
end

-- 获取 hlist 内部的单个 glyph 子节点（竖排文本中字符被包装为 hlist）
local function hlist_glyph(h)
    if h.id == hlist_id then
        local list = h.list
        if list and list.id == glyph_id and not list.next then
            return list
        end
    end
    return nil
end

-- 获取节点的字符（兼容 glyph 和 hlist 内的 glyph）
local function node_char(n)
    if n.id == glyph_id then return n.char end
    local g = hlist_glyph(n)
    return g and g.char or nil
end

-- 获取节点的字体（兼容 glyph 和 hlist 内的 glyph）
local function node_font(n)
    if n.id == glyph_id then return n.font end
    local g = hlist_glyph(n)
    return g and g.font or nil
end

-- 缓存清理：font ID 只增不减，fonts 映射会随字体实例数无限增长。
-- 以 fontdata 为权威重建映射；同时回收不再被任何存活字体引用的标点数据。
-- （回收是安全的：若字体再次出现，punc_data 会重新计算。）
local function cleanup_cache()
    local puncs_font = thirddata.zhpunc.puncs_font

    local refcount = {}
    for font_id, fdata in next, fontdata do
        local key = get_font_cache_key(font_id)
        refcount[key] = (refcount[key] or 0) + 1
    end

    local reaped = 0
    for key, _ in next, puncs_font do
        if not refcount[key] then
            puncs_font[key] = nil
            reaped = reaped + 1
        end
    end

    if thirddata.zhpunc.debug then
        print(string.format("[zhpunc] cleanup_cache: puncs_font entries=%d, fontdata entries=%d, reaped=%d",
            (function() local n=0 for _ in next, puncs_font do n=n+1 end return n end)(),
            (function() local n=0 for _ in next, fontdata do n=n+1 end return n end)(),
            reaped))
    end
    return reaped
end

-- =========================================================
-- 分类判断函数
-- =========================================================
local function get_punc_class(char)
    local c = char_class_cache[char]
    if c ~= nil then
        if c == false then return nil end
        return c
    end
    c = user_char_class[char]
    if not c then c = puncs[char] end
    char_class_cache[char] = c or false
    return c
end

local function is_hangjian_punc(char)
    local v = user_hangjian[char]
    if v ~= nil then return v end
    return puncs_to_hangjian[char] or false
end

local function is_rotate_punc(char)
    local v = user_rotate[char]
    if v ~= nil then return v end
    return puncs_to_rotate[char] or false
end

local function is_protrude_left_punc(char)
    local v = user_protrude_left[char]
    if v ~= nil then return v end
    return get_punc_class(char) == puncs_left_sign
end

local function is_protrude_right_punc(char)
    local v = user_protrude_right[char]
    if v ~= nil then return v end
    return protrude_right_classes[get_punc_class(char)] or false
end

local function is_forbid_start_punc(char)
    local v = user_forbid_start[char]
    if v ~= nil then return v end
    local class = get_punc_class(char)
    return class == puncs_right_sign
        or class == puncs_inner_point
        or class == puncs_ending_point
        or class == puncs_repeat_sign
        or class == puncs_dakuten
end

local function is_forbid_end_punc(char)
    local v = user_forbid_end[char]
    if v ~= nil then return v end
    return get_punc_class(char) == puncs_left_sign
end

-- 清空缓存（用户配置变化 / 模式切换时调用）
local function clear_punc_cache()
    for k in next, is_punc_cache_h  do is_punc_cache_h[k]  = nil end
    for k in next, is_punc_cache_v  do is_punc_cache_v[k]  = nil end
    for k in next, char_class_cache do char_class_cache[k] = nil end
    for k in next, char_type_cache  do char_type_cache[k]  = nil end
    for k in next, char_shift_cache do char_shift_cache[k] = nil end
end

-- 仅依赖 char 与 appended 状态的查表
local function is_punc_of_char(char)
    local appended = thirddata.vtypeset.appended
    local cache = appended and is_punc_cache_v or is_punc_cache_h
    local v = cache[char]
    if v ~= nil then return v end
    
    local result
    if appended and is_rotate_punc(char) then
        result = 2
    elseif get_punc_class(char) then
        result = 1
    else
        result = false
    end
    cache[char] = result
    return result
end

-- 是标点结点
-- @n: glyph | hlist
-- @return: false | 1 | 2 （不是标点 | 一般标点 | 将要旋转的标点）
local function is_punc(n)
    local g
    if n.id == glyph_id then
        g = n
    elseif n.id == hlist_id then
        g = hlist_glyph(n)
    end
    if not g then return false end
    return is_punc_of_char(g.char)
end

-- 是占几角结点
-- @n: glyph | hlist
-- @return: boolean
-- 返回占位角数（1 全角 / 0.5 半角 / 用户自定义），非标点返回 nil
local function get_punc_quad(n)
    local char = node_char(n)
    if not char then return nil end

    -- 1. 用户显式设置最优先
    local uq = user_quad_ref[char]
    if uq ~= nil then return uq end

    -- 2. 内置全角表
    if full_quad_puncs[char] then return 1 end
    if thirddata.vtypeset.appended and v_full_quad_puncs[char] then return 1 end

    -- 3. 是标点则默认半角
    if is_punc(n) then return 0.5 end
    return nil
end

local function is_left_sign(n)
    local c = node_char(n)
    return c and get_punc_class(c) == puncs_left_sign or false
end

local right_sign_classes = {
    [puncs_right_sign]   = true,
    [puncs_inner_point]  = true,
    [puncs_ending_point] = true,
}

local function is_right_sign(n)
    local c = node_char(n)
    return c and right_sign_classes[get_punc_class(c)] or false
end

local visible_node_ids = {
    [hlist_id] = true,
    [vlist_id] = true,
    [rule_id ] = true,
    [glyph_id] = true,
}

-- 后一个可见节点是标点
local function next_punc(n)
    local next_n = n.next
    while next_n do
        local id = next_n.id
        if id == glyph_id then
            if is_punc_of_char(next_n.char) then
                return next_n
            else
                return false
            end
        elseif id == hlist_id then
            local g = hlist_glyph(next_n)
            if g and is_punc_of_char(g.char) then
                return next_n
            else
                return false
            end
        elseif id == vlist_id or id == rule_id then
            return false
        end
        next_n = next_n.next
    end
    return nil
end

-- 前一个可见节点是标点
local function prev_punc(n)
    local prev_n = n.prev
    while prev_n do
        local id = prev_n.id
        if id == glyph_id then
            if is_punc_of_char(prev_n.char) then
                return prev_n
            else
                return false
            end
        elseif id == hlist_id then
            local g = hlist_glyph(prev_n)
            if g and is_punc_of_char(g.char) then
                return prev_n
            else
                return false
            end
        elseif id == vlist_id or id == rule_id then
            return false
        end
        prev_n = prev_n.prev
    end
    return nil
end

-- 标点类别，-1：左；0：中；1：右
local function punc_class(n)
    if is_left_sign(n) then
        return  -1
    elseif is_right_sign(n) then
        return 1
    else
        return 0
    end
end

-- 统一获取字符分类
local function get_char_type(char)
    local cur_type = char_type_cache[char]
    if cur_type then return cur_type end

    if char == 0 then
        cur_type = TYPE_NONE
    elseif is_punc_of_char(char) then
        cur_type = TYPE_PUNCT
    elseif is_chinesechar(char) then
        cur_type = TYPE_CJK
    else
        cur_type = TYPE_OTHER
    end
    char_type_cache[char] = cur_type
    return cur_type
end

-- 直接取字形节点（内联 hlist_glyph 逻辑，避免函数调用）
local function direct_glyph(n)
    local id = n.id
    if id == glyph_id then return n end
    if id == hlist_id then
        local g = n.list
        if g and g.id == glyph_id and not g.next then return g end
    end
    return nil
end
-- =========================================================
-- 核心节点操作函数
-- =========================================================
local function node_remove_list(head, n, m)
    while n and n ~= m do
        local next_n = n.next
        head,_ = node_remove(head, n)
        node_free(n)
        n = next_n
    end
    return head, n
end

-- 剪切从某个起始的同类标点（左标点、右标点、其余/中标点）组
local function cut_punc_group(head, n)
    local begin = n
    local p_class = punc_class(n)
    local the_end = n.next
    n = next_punc(n)
    while n do
        local c = node_char(n)
        if c and is_hangjian_punc(c) and p_class == punc_class(n) then
            the_end = n.next
            n = next_punc(n)
        else
            break
        end
    end

    -- 覆盖前后的kern TODO 更可靠的逻辑
    local pre = begin.prev
    if pre and pre.id == kern_id then
        begin = pre
    end
    -- 取消前置胶的弹性 TODO 更可靠的逻辑
    pre = begin.prev
    if pre and pre.id == glue_id then
        pre.stretch = 0
        pre.shrink = 0
    end
    if the_end and the_end.id == kern_id then
        the_end = the_end.next
    end
    local copyed_list = node_copylist(begin, the_end)
    local current
    head, current = node_remove_list(head, begin, the_end)
    return head, current, copyed_list, p_class
end

-- 以hlist形式插入列表
local function insert_list_before(head, current, list, p_class,quad)
    -- 模拟\hss，插入列表首尾
    local hss        = node_new(glue_id)
    hss.width        = 0
    hss.stretch      = 65536
    hss.shrink       = 65536
    hss.stretchorder = 2
    hss.shrinkorder  = 2
    if p_class == 1 then
        list,_ = node_insertbefore(list, list, hss)
    elseif p_class == -1 then
        list,_ = node_insertafter(list, node_tail(list), hss)
    end

    -- 把列表装入0宽度的盒子中
    local box, _ = node_hpack(list,0,"exactly")
    box.shift = -quad * thirddata.zhpunc.hangjian_shift

    head, current = node_insertbefore(head,current, box)

    return head, current
end

local function mark(tbl, char, val)
    return tostring(val) .. (tbl[char] ~= nil and " (user)" or " (default)")
end

-- 计算、缓存并返回标点数据
function thirddata.zhpunc.punc_data(n)

    local puncs_font = zhpunc.puncs_font
    local char, font_id
    if n.id == glyph_id then
        char, font_id = n.char, n.font
    else
        local g = hlist_glyph(n)
        if not g then return nil end
        char, font_id = g.char, g.font
    end
    if not char then return nil end

   -- 快速路径：缓存命中直接返回，避免重复的表操作和统计
    local cache_key = font_id_to_key[font_id]
    if cache_key then
        local font_cache = zhpunc.puncs_font[cache_key]
        if font_cache then
            local char_cache = font_cache[char]
            if char_cache and next(char_cache) then
                return char_cache
            end
        end
    else
        cache_key = get_font_cache_key(font_id)
    end

    local puncs_font = zhpunc.puncs_font
    -- 左右实际kern
    local l_kern
    local r_kern
    -- 单侧空白（两侧相同）
    local one_side_space

    -- 更新 font ID 到 cache_key 的映射
    -- thirddata.zhpunc._cache_stats.fonts[font_id] = cache_key
    puncs_font[cache_key] = puncs_font[cache_key] or {}

    -- 空铅
    local fd = fontdata[font_id]
    local quad_val = fd and fd.parameters and fd.parameters.quad
    puncs_font[cache_key]["quad"] =
        puncs_font[cache_key]["quad"] or (quad_val or 655360)
    -- 英文字体quad多变，稳定的是fontdata[font].parameters.units-- em的单元数，通常是1000
    local quad = puncs_font[cache_key]["quad"]

    puncs_font[cache_key][char] = puncs_font[cache_key][char] or {}

    -- 调试：打印缓存统计信息
    -- 计数无条件自增（代价极小），触发清理与 debug 打印解耦
    local stats = thirddata.zhpunc._cache_stats
    stats.access_count = stats.access_count + 1
    if stats.access_count - stats.last_cleanup >= (stats.interval or 10000) then
        stats.last_cleanup = stats.access_count
        local reaped = cleanup_cache()
        if thirddata.zhpunc.debug then
            print(string.format("[zhpunc] cache cleanup: reaped %d font entries, %d accesses",
                reaped, stats.access_count))
        end
    end

    -- 检查缓存是否已存在（使用 next 检查表是否为空）
    if not next(puncs_font[cache_key][char]) then
        local fdata = fontdata[font_id]
        local desc = fdata and fdata.descriptions and fdata.descriptions[char]
        local desc_width = desc and desc.width
        local boundingbox = desc and desc.boundingbox
        if not desc_width or desc_width == 0 or not boundingbox then
            return nil
        end
        local x1 = boundingbox[1]
        local x2 = boundingbox[3]
        
        local w_in --内框宽度
        local left_space --前空
        local right_space -- 后空
        local pt = is_punc(n)
        if pt == 1 then -- 一般标点
            left_space = x1
            right_space = desc_width - x2
            w_in = x2 - x1
        elseif pt == 2 then --旋转的标点
            left_space = x1
            -- 有些字体可能没有深度（整体在线上时）、高度（整体在线下时）数据
            local desc_depth  = desc.depth  or -desc.boundingbox[2]
            local desc_height = desc.height or 0
            right_space = desc_width - left_space - desc_depth - desc_height
            w_in =  desc_depth + desc_height
        else
            left_space = 0
            right_space = 0
            w_in = 0
        end
        puncs_font[cache_key][char]["left_space"] = left_space / desc_width * quad
        puncs_font[cache_key][char]["right_space"] = right_space / desc_width * quad

        local pquad = get_punc_quad(n) or 0.5
        local two_space
        two_space = desc_width * pquad - w_in 
        -- 原本逻辑
        -- 半角/自定义：按角数比例
        -- 全角：两侧空 = 字框宽 - 墨迹宽
        -- 现在一律按照 角数比例 计算

        -- 墨迹比占位空间还宽时，不做左右 kern，避免负 kern 导致重叠
        if two_space < 0 then
            l_kern = 0
            r_kern = 0
            one_side_space = 0
        else
            -- 再居中
            l_kern = (two_space/2 - left_space) / desc_width * quad  --左kern
            r_kern = (two_space/2 - right_space) / desc_width * quad --右kern
            one_side_space = (two_space/2)  / desc_width * quad
        end

        puncs_font[cache_key][char]["l_kern"] = l_kern
        puncs_font[cache_key][char]["r_kern"] = r_kern
        puncs_font[cache_key][char]["one_side_space"] = one_side_space
        puncs_font[cache_key][char]["quad"] = quad
        
        if thirddata.zhpunc.debug then
            local char_str = utf8.char(char)
            print(string.format("[zhpunc] 标点: %s (U+%04X)", char_str, char))
            -- 单位换算：desc_width/w_in/left_space/right_space/two_space 是字体单位
            -- （units per em），要按 quad/desc_width 换成 sp 再显示；
            -- l_kern/r_kern/one_side_space 已经是 sp，直接 /65536。
            local u2sp = quad / desc_width
            print(string.format("  字体: %s, quad: %.2fpt", cache_key, quad/65536))
            print(string.format("  外框宽: %.2fpt, 内框宽: %.2fpt", desc_width*u2sp/65536, w_in*u2sp/65536))
            print(string.format("  左空白: %.2fpt, 右空白: %.2fpt", left_space*u2sp/65536, right_space*u2sp/65536))
            print(string.format("  两侧总空: %.2fpt, 单侧空: %.2fpt", two_space*u2sp/65536, one_side_space/65536))
            print(string.format("  l_kern: %.2fpt, r_kern: %.2fpt", l_kern/65536, r_kern/65536))
            print(string.format("  类别: %s", tostring(get_punc_class(char))))
            print(string.format("  凸排: 左=%s 右=%s",
                mark(thirddata.zhpunc.user_protrude_left,  char, is_protrude_left_punc(char)),
                mark(thirddata.zhpunc.user_protrude_right, char, is_protrude_right_punc(char))))
            print(string.format("  禁排: 行首=%s 行尾=%s",
                mark(thirddata.zhpunc.user_forbid_start, char, is_forbid_start_punc(char)),
                mark(thirddata.zhpunc.user_forbid_end,   char, is_forbid_end_punc(char))))
            print(string.format("  raw: desc.width=%d, quad=%d, bbox={%d,%d,%d,%d}",
                desc_width, quad,
                boundingbox[1], boundingbox[2], boundingbox[3], boundingbox[4]))
        end
    end
    return puncs_font[cache_key][char]
end

-- 从 n 沿 field（"prev"/"next"）方向找第一个可收缩的 glue；
-- 途中只允许经过 penalty，遇到其他结点即停止（返回 nil）
local function find_shrink_glue(n, field)
    local c = n[field]
    while c do
        local id = c.id
        if id == glue_id then
            if c.shrink > 0 then return c end
        elseif id ~= penalty_id then
            return nil
        end
        c = c[field]
    end
end

-- 在 ref_node 前/后插入加空 glue（角数 × quad × space_quad）
-- label 仅用于 debug 打印
local function insert_space(head, ref_node, before, angle, quad, label)
    local space = node_new(glue_id)
    space.width = angle * quad * thirddata.zhpunc.space_quad
    if before then
        head, _ = node_insertbefore(head, ref_node, space)
    else
        head, _ = node_insertafter(head, ref_node, space)
    end
    if thirddata.zhpunc.debug then
        local char = node_char(ref_node)
        print(string.format("  [%s加空] %s (U+%04X) %.2fpt",
            label,
            char and utf8.char(char) or "?", char or 0,
            space.width / 65536))
    end
    return head
end

-- 通用禁排惩罚：为任何符合条件的字形节点（标点或非标点）补 penalty
local function apply_forbid_penalty(head, n, char, char_class)
    if not char then return head end

    -- 行尾禁排：用户值优先（含 false），否则按 char_class 判断
    local ufe = user_forbid_end[char]
    local forbid_end
    if ufe ~= nil then
        forbid_end = ufe
    else
        forbid_end = (char_class ~= nil) and (char_class == puncs_left_sign)
    end

    if forbid_end then
        local g = n.next
        while g and g.id == kern_id do
            g = g.next
        end
        if g and g.id == glue_id then
            local prev_node = g.prev
            if not (prev_node and prev_node.id == penalty_id and prev_node.penalty >= 10000) then
                local p = node_new(penalty_id)
                p.penalty = 10000
                head, _ = node_insertbefore(head, g, p)
            end
        end
    end

    -- 行首禁排：用户值优先（含 false），否则按 char_class 判断
    local ufs = user_forbid_start[char]
    local forbid_start
    if ufs ~= nil then
        forbid_start = ufs
    else
        forbid_start = (char_class ~= nil)
            and (char_class == puncs_right_sign
                or char_class == puncs_inner_point
                or char_class == puncs_ending_point
                or char_class == puncs_repeat_sign
                or char_class == puncs_dakuten)
    end

    if forbid_start then
        local break_glue
        local g = n.prev
        while g and (g.id == glue_id or g.id == kern_id) do
            if g.id == glue_id then
                break_glue = g
            end
            g = g.prev
        end
        if break_glue then
            local prev_node = break_glue.prev
            if not (prev_node and prev_node.id == penalty_id and prev_node.penalty >= 10000) then
                local p = node_new(penalty_id)
                p.penalty = 10000
                head, _ = node_insertbefore(head, break_glue, p)
            end
        end
    end

    return head
end

local function process_punc(head, n, char, char_class)
    if not char then return head end

    local p_data = thirddata.zhpunc.punc_data(n)
    if not p_data then return head end

    local model  = zhpunc.model 
    local quad   = p_data["quad"]
    local l_kern = p_data["l_kern"]
    local r_kern = p_data["r_kern"]
    local one_side_space = p_data["one_side_space"]

    local prev_p = prev_punc(n)
    local next_p = next_punc(n)

    -- 用户定义的前加空规则（角数）。有规则时不再插入 l_kern（避免抵消前加空效果）
    local pre_space
    if prev_p == false then
        local space_table = inserting_space[model]
        if space_table and space_table[puncs_no] and space_table[puncs_no][char_class] then
            pre_space = space_table[puncs_no][char_class]
        end
    end

    -- 用户自定义加空（角数），与 model、全/半角无关
    -- 一旦设置，则完全取代该字符的默认 model 加空（避免叠加），
    -- 但默认的半角压缩（l_kern/r_kern）仍正常进行。
    local user_space = user_space_ref[char]
    if user_space then
        if user_space.after and next_p == false then
            head = insert_space(head, n, false, user_space.after, quad, "用户后")
        end
        if user_space.before and prev_p == false then
            head = insert_space(head, n, true, user_space.before, quad, "用户前")
            pre_space = true
        end
    end

    -- 实际占位半角的标点可能加空（用户未显式接管时才按默认规则）
    -- 任何"不足全角"的占位都按半角逻辑参与 model 加空
    if not user_space and (model == quanjiao or model == kaiming) then
        local space_table = inserting_space[model]
        
        -- 后加空
        local next_space
        local next_space_table = space_table[char_class]
        if next_space_table then
            if next_p then -- 后面是标点
                next_space = next_space_table[get_punc_class(node_char(next_p))]
            elseif next_p == false then -- 是非标点可见结点（不是末尾nil）
                next_space = next_space_table[puncs_no]
            end
            if next_space then
                head = insert_space(head, n, false, next_space, quad, "后")
            end
        end
        
        -- 前加空
        if pre_space then
            head = insert_space(head, n, true, pre_space, quad, "前")
        end
    end

    if model ~= yuanyang then
        local no_kern = (l_kern == 0 and r_kern == 0 and one_side_space == 0)

        if not no_kern then
            local k
            local shrink_glue
            
            -- 如果 l_kern 是正数，创建一个带收缩量的 glue 代替 ker n
            if l_kern > 0 then
                local g = node_new(glue_id)
                g.width = l_kern        -- 理想宽度（居中效果）
                g.stretch = 0           -- 不拉伸
                g.shrink = l_kern       -- 允许收缩
                head,k = node_insertbefore (head, n, g)
            elseif l_kern < 0 then -- 负数依然用 kern 或者宽度为负的 glue 都行
                head,k = node_insertbefore (head, n, nodes_pool_kern (l_kern))
            else
                k = n 
            end
            shrink_glue = find_shrink_glue(k, "prev")
            if shrink_glue then --前面的收缩，考虑前面是标点的情况
                local shrink = one_side_space
                if prev_p then
                    local prev_p_data = thirddata.zhpunc.punc_data(prev_p)
                    if prev_p_data then
                        shrink = one_side_space + prev_p_data["one_side_space"]
                    end
                end
                shrink_glue.shrink = shrink
            end
            
            head,k = node_insertafter (head, n, nodes_pool_kern (r_kern))
            if not next_p then --仅处理后面不是标时
                shrink_glue = find_shrink_glue(k, "next")
                if shrink_glue then
                    shrink_glue.shrink = one_side_space
                end
            end
        end
    end

    -- 句内点号（、，：；）后面显式允许断行。
    -- 英文语境下 、 前后都是非 CJK，没有 interchar glue，
    -- 只有 kern，TeX 无法在 kern 处断行，导致长英文列表 overfull。
    if char_class == puncs_inner_point then
        local pen = node_new(penalty_id)
        pen.penalty = 0
        -- 插在 r_kern 之后（如果 r_kern 是负的，kern 已经在 n 后面）
        local anchor = n
        local next_n = n.next
        if next_n and next_n.id == kern_id then
            anchor = next_n
        end
        head, _ = node_insertafter(head, anchor, pen)
    end

    return head

end

-- 处理基线偏移
local function apply_shift(n, char, amount)
    if not amount or amount == 0 then return false end
    local st = char_shift_cache[char]
    if st == nil then
        st = is_shift_class(char)
        char_shift_cache[char] = st
    end
    if st then
        n.yoffset = (n.yoffset or 0) + amount
        if thirddata.zhpunc.debug_shift then
            print(string.format("SHIFT %s '%s' U+%04X yoffset=%d",
                st, utf8.char(char), char, n.yoffset))
        end
        return st
    end
    return false
end

-- 处理盘古之白
local function apply_pangu(head, n, glue_kind, prev_char, cur_char)
    local glue_template = (glue_kind == "kanji")  and kanji_glue
                       or (glue_kind == "xkanji") and xkanji_glue
    if not glue_template then return head, false end

    local should_insert = true
    local action = "INSERT"
    local old_desc = "-"
    local p_node = n.prev

    -- 回溯：跳过 whatsit / math 边界等非文本节点
    while p_node and p_node.id ~= glue_id
          and p_node.id ~= glyph_id and p_node.id ~= hlist_id do
        p_node = p_node.prev
    end

    if p_node and p_node.id == glue_id then
        if thirddata.zhpunc.debug_pangu then
            old_desc = glue_name(p_node) .. " (" .. glue_metrics(p_node) .. ")"
        end
        local st = p_node.subtype
        if st == INTERCHAR_SUBTYPE then
            if glue_kind == "kanji" then
                p_node.width = kanji_glue_template.width   -- 只改 width
                should_insert = false; action = "UNIFY-INTERCHAR"
            else
                should_insert = false; action = "KEEP"
            end
        elseif st == KANJISKIP_SUBTYPE or st == XKANJISKIP_SUBTYPE then
            -- 无条件统一为模板值
            p_node.width   = glue_template.width
            p_node.stretch = glue_template.stretch
            p_node.shrink  = glue_template.shrink
            p_node.subtype = (glue_kind == "kanji")
                             and KANJISKIP_SUBTYPE or XKANJISKIP_SUBTYPE
            should_insert  = false
            action         = (glue_kind == "kanji") and "UNIFY-K" or "UNIFY-X"
        elseif glue_kind == "xkanji" then
            -- 普通空格 → 原地改写为 xkanjiskip
            p_node.width   = glue_template.width
            p_node.stretch = glue_template.stretch
            p_node.shrink  = glue_template.shrink
            p_node.subtype = XKANJISKIP_SUBTYPE
            should_insert  = false
            action         = "UNIFY-SP"
        else
            should_insert = false; action = "SKIP"
        end
    end

    if should_insert then
        local glue = node_copy(glue_template)
        head = node_insertbefore(head, n, glue)
    end

    if thirddata.zhpunc.debug_pangu then
        local new_desc
        if should_insert then
            new_desc = glue_name(glue_template) .. " (" .. glue_metrics(glue_template) .. ")"
        elseif p_node then
            new_desc = glue_name(p_node) .. " (" .. glue_metrics(p_node) .. ")"
        else
            new_desc = "-"
        end
        print(string.format(
            "[Pangu] %-8s | old=%-28s | new=%-28s | '%s'(U+%04X) -> '%s'(U+%04X)",
            action, old_desc, new_desc,
            utf8.char(prev_char), prev_char,
            utf8.char(cur_char),  cur_char))
    end
    
    return head, should_insert
end

-- =========================================================
-- 主控制流程
-- =========================================================
function thirddata.zhpunc.process_all(head)
    local handler = scripts.handlers and scripts.handlers.hanzi
    local d = handler and handler.datasets and handler.datasets.custom
    local amount   = tex.dimen["ybaselineshift"]
    local do_shift = amount and amount ~= 0
    local do_insert = d ~= nil

    if not do_insert and not do_shift and not thirddata.zhpunc.enabled then
        return head, true
    end

    local cfg = {
        k = { width = 0, stretch = 0, shrink = 0 },
        x = { width = 0, stretch = 0, shrink = 0 },
    }
    if do_insert then
        cfg.k.width   = d.fixed_kanji_width_em        or 0
        cfg.k.stretch = d.inter_char_stretch_factor   or 0   -- 改：从 interchar 读
        cfg.k.shrink  = d.inter_char_shrink_factor    or 0   -- 改：从 interchar 读
        cfg.x.width   = d.fixed_xkanji_width_em       or 0
        cfg.x.stretch = d.fixed_xkanji_stretch_factor or 0   -- 不变（盘古之白独立）
        cfg.x.shrink  = d.fixed_xkanji_shrink_factor  or 0   -- 不变
    end

    local prev_type = nil
    local prev_char = nil
    local n_insert, n_skip = 0, 0
    local n = head
    
    lastfont = nil
    templates_dirty = false

    if thirddata.zhpunc.debug_pangu then
        print("[Pangu] =====================================")
        print(string.format("[Pangu] process START | k_em=%.4f x_em=%.4f xs=%.4f xh=%.4f shift=%s",
            cfg.k.width, cfg.x.width, cfg.x.stretch, cfg.x.shrink, tostring(do_shift)))
    end

    while n do
        local cur_char, cur_font
        if n.id == glyph_id then
            cur_char = n.char
            cur_font = n.font
        elseif n.id == hlist_id then
            local g = n.list
            if g and g.id == glyph_id and not g.next then
                cur_char = g.char
                cur_font = g.font
            end
        end

        if cur_char then
            -- 2. Shift
            if do_shift then
                apply_shift(n, cur_char, amount)
            end

            -- 3. 盘古
            local cur_type
            if do_insert then
                cur_type = char_type_cache[cur_char]
                if not cur_type then
                    if cur_char == 0 then
                        cur_type = TYPE_NONE
                    elseif is_punc_of_char(cur_char) then
                        cur_type = TYPE_PUNCT
                    elseif is_chinesechar(cur_char) then
                        cur_type = TYPE_CJK
                    else
                        cur_type = TYPE_OTHER
                    end
                    char_type_cache[cur_char] = cur_type
                end
                -- 预判：只有 cur_type 是 CJK（保证模板刷新），
                -- 或 prev_type 是 CJK 且 cur_type 是 OTHER（盘古之白），
                -- 才需要调用 apply_pangu。PUNCT、OTHER-OTHER 直接跳过。
                local need_pangu = (cur_type == TYPE_CJK)
                    or (prev_type == TYPE_CJK and cur_type == TYPE_OTHER)
                if need_pangu then
                    -- 模板刷新条件外提：只有字体变化或 dirty 时才真正刷新
                    -- （原逻辑每次都进 refresh_templates，内部早退；外提后省一次函数调用）
                    if (cur_type == TYPE_CJK or not lastfont)
                        and (cur_font ~= lastfont or templates_dirty) then
                        refresh_templates(cur_font, cfg)
                    end
                    local glue_kind = prev_type and insert_rules[prev_type][cur_type]
                    if glue_kind then
                        -- 模板存在性预判：kanji_glue/xkanji_glue 为 nil 时
                        -- apply_pangu 会立即返回，此处提前跳过避免无效调用
                        local template = (glue_kind == "kanji")  and kanji_glue
                                       or (glue_kind == "xkanji") and xkanji_glue
                        if template then
                            local inserted
                            head, inserted = apply_pangu(head, n, glue_kind, prev_char, cur_char)
                            if thirddata.zhpunc.debug_pangu then
                                if inserted then n_insert = n_insert + 1 else n_skip = n_skip + 1 end
                            end
                        end
                    end
                end
                if cur_type ~= TYPE_NONE then
                    prev_type = cur_type
                    prev_char = cur_char
                end
            end

            -- 4. 标点处理与禁排
            if thirddata.zhpunc.enabled then
                -- do_insert 为真时复用 cur_type，否则单独查
                local is_p
                if do_insert then
                    is_p = (cur_type == TYPE_PUNCT)
                else
                    is_p = is_punc_of_char(cur_char)
                end

                local ufs = user_forbid_start[cur_char]
                local ufe = user_forbid_end[cur_char]
                local need_forbid = is_p or ufs ~= nil or ufe ~= nil

                -- 只在需要时算一次 char_class，process_punc 和 apply_forbid_penalty 共用
                local char_class
                if need_forbid then
                    char_class = get_punc_class(cur_char)
                end

                if is_p then
                    head = process_punc(head, n, cur_char, char_class)
                end
                if need_forbid then
                    head = apply_forbid_penalty(head, n, cur_char, char_class)
                end
            end
        end

        -- =========================================================
        -- 5. 安全跳转到下一个真实文本节点（用 ID 判断，避免 node_char）
        -- =========================================================
        n = n.next
        while n and n.id ~= glyph_id and n.id ~= hlist_id do
            n = n.next
        end
    end

    if thirddata.zhpunc.debug_pangu then
        print(string.format("[Pangu] process END | inserted=%d skipped=%d", n_insert, n_skip))
        print("[Pangu] =====================================")
    end

    return head, true
end

-- 实现行间标点
local function raise_punc_to_hangjian(head)
    local n = head
    while n do
        local id = n.id
        if id == glyph_id or id == hlist_id then
            local char = node_char(n)
            if char and is_hangjian_punc(char) then
                thirddata.zhpunc.punc_data(n) --更新标点数据
                local cache_key = get_font_cache_key(node_font(n))
                local quad = thirddata.zhpunc.puncs_font[cache_key]["quad"]

                local list, p_class
                head, n, list, p_class = cut_punc_group(head,n)
                head, n = insert_list_before(head, n, list, p_class, quad)
            else
                n = n.next
            end
        else
            n = n.next
        end
    end
    return head
end

-- 将指定 kern 节点相邻的 kern 清零，避免与正常 kern 叠加
local function zero_adjacent_kern(kern, dir)
    local adj = dir == "prev" and kern.prev or kern.next
    if adj and adj.id == kern_id then
        adj.kern = 0
    end
end

-- 两端凸排
function thirddata.zhpunc.protrude(head)
    -- show_detail(head,"before")

    local is_changed = false

    -- 左侧（行首凸排）
    local head_p = next_punc(head)
    if head_p and is_protrude_left_punc(node_char(head_p)) then
        local n_data = thirddata.zhpunc.punc_data(head_p)
        if n_data then
            local left_space = n_data["left_space"]
            local kern = node_new(kern_id, "leftmarginkern")
            kern.kern = -left_space
            head, kern = node_insertbefore(head, head_p, kern)
            zero_adjacent_kern(kern, "prev")
            is_changed = true
        end
    end
    
    -- 右侧（行尾凸排）
    local tail_p = prev_punc(node_tail(head))
    if tail_p and is_protrude_right_punc(node_char(tail_p)) then
        local n_data = thirddata.zhpunc.punc_data(tail_p)
        if n_data then
            local right_space = n_data["right_space"]
            local kern = node_new(kern_id, "rightmarginkern")
            kern.kern = -right_space
            head, kern = node_insertafter(head, tail_p, kern)
            zero_adjacent_kern(kern, "next")
            is_changed = true
        end
    end
    
    -- show_detail(head,"after")
    return head, is_changed
end

function thirddata.zhpunc.protrude_main(head)
    if not thirddata.zhpunc.enabled then
        return head, true
    end
    local n = head
    while n do
        if n.id == hlist_id then
            local new_list, is_changed = thirddata.zhpunc.protrude(n.head)
            if is_changed then
                n.head = nil                       -- 解绑，防止共享
                local new_n = node_hpack(new_list, n.width, "exactly")
                head, new_n = node_insertbefore(head, n, new_n)
                head, n = node_remove(head, n, true)
            else
                n = n.next
            end
        else
            n = n.next
        end
    end
    return head, true
end

-- 独立处理行间标点（在节点流基本稳定后）
function thirddata.zhpunc.process_hangjian(head)
    if thirddata.zhpunc.enabled and thirddata.zhpunc.hangjian then
        head = raise_punc_to_hangjian(head)
    end
    return head, true
end

-- =========================================================
-- 对外接口与配置
-- =========================================================
-- 传参设置
-- 接收键值对字符串：\setupzhpunc[pattern=..., spacequad=..., hangjianshift=..., hangjian=..., lineend=..., debug=...]
-- 缺省键保留原值，便于部分覆盖。
function thirddata.zhpunc.set(params)
    local settings = utilities.parsers.settings_to_hash(params or "") or {}

    local pattern = settings.pattern
    if pattern == quanjiao or pattern == kaiming
    or pattern == banjiao or pattern == yuanyang then
        thirddata.zhpunc.model = pattern
    end

    if settings.hangjian ~= nil then
        thirddata.zhpunc.hangjian = bool_val(settings.hangjian)
    end

    if settings.spacequad ~= nil then
        thirddata.zhpunc.space_quad = tonumber(settings.spacequad) or thirddata.zhpunc.space_quad
    end

    if settings.hangjianshift ~= nil then
        thirddata.zhpunc.hangjian_shift = tonumber(settings.hangjianshift) or thirddata.zhpunc.hangjian_shift
    end

    if settings.debug ~= nil then
        local on = bool_val(settings.debug)
        thirddata.zhpunc.debug       = on
        thirddata.zhpunc.debug_pangu = on
        thirddata.zhpunc.debug_shift = on
        if on then
            print("[zhpunc] Debug mode enabled (debug, debug_pangu, debug_shift)")
        end
    end
end

-- 挂载/启动任务
function thirddata.zhpunc.append()
    if thirddata.zhpunc.appended then return end
    nodes_tasks_appendaction("processors", "after", "thirddata.zhpunc.process_all")
    nodes_tasks_appendaction("processors", "after", "thirddata.zhpunc.process_hangjian")
    nodes_tasks_appendaction("finalizers", "after", "thirddata.zhpunc.protrude_main")
    thirddata.zhpunc.appended = true
end

-- ========== 用户扩展符号类别接口 ==========
-- 定义新的符号类别
-- @class_name: 类别名（如 "ordinal", "middle"）
-- @params: 参数字符串
function thirddata.zhpunc.define_class(class_name, params)
    if not class_name or class_name == "" then
        print("[zhpunc] Error: class name is required")
        return
    end

    -- 短名（left/right/…）展开为完整类别名，与 add_to_class、
    -- get_punc_class 保持同一命名空间，否则 inserting_space 查不到。
    local resolved = resolve_class(class_name)

    local parsed = utilities.parsers.settings_to_hash(params) or {}

    thirddata.zhpunc.user_classes[resolved] = {
        punc           = opt_bool(parsed.punc),
        protrude_left  = opt_bool(parsed.protrudeleft),
        protrude_right = opt_bool(parsed.protruderight),
        forbid_start   = opt_bool(parsed.forbidstart),
        forbid_end     = opt_bool(parsed.forbidend),
        quad           = tonumber(parsed.quad),
        space_before   = tonumber(parsed.spacebefore) or 0,
        space_after    = tonumber(parsed.spaceafter) or 0,
    }

    -- 将新类别添加到 inserting_space 表中（供默认半角压缩逻辑沿用）
    if not inserting_space[kaiming] then inserting_space[kaiming] = {} end
    if not inserting_space[quanjiao] then inserting_space[quanjiao] = {} end

    local space_quad   = thirddata.zhpunc.space_quad or 0.5
    local space_before = thirddata.zhpunc.user_classes[resolved].space_before
    local space_after  = thirddata.zhpunc.user_classes[resolved].space_after

    if space_after > 0 then
        local insert_value = space_after / space_quad
        inserting_space[kaiming][resolved]  = {[puncs_no] = insert_value}
        inserting_space[quanjiao][resolved] = {[puncs_no] = insert_value}
    end
    if space_before > 0 then
        local insert_value = space_before / space_quad
        inserting_space[kaiming][puncs_no]  = inserting_space[kaiming][puncs_no]  or {}
        inserting_space[quanjiao][puncs_no] = inserting_space[quanjiao][puncs_no] or {}
        inserting_space[kaiming][puncs_no][resolved]  = insert_value
        inserting_space[quanjiao][puncs_no][resolved] = insert_value
    end

    clear_punc_cache()
end

-- 添加符号到类别
-- @class_name: 类别名（可以是预定义类别或用户定义类别）
-- @chars_str: 符号字符串（如 "☆★○●"）
function thirddata.zhpunc.add_to_class(class_name, chars_str)
    if not class_name or not chars_str then
        print("[zhpunc] Error: class name and chars are required")
        return
    end
    
    local chars = parse_chars(chars_str)
    
    local target_class = resolve_class(class_name)

    local class_props = thirddata.zhpunc.user_classes[target_class] or {}

    -- 校验：未知类别发出警告（不中断），避免用户误用却无从察觉
    local is_predefined = puncs_class_map[class_name] ~= nil
    if not is_predefined and not thirddata.zhpunc.user_classes[target_class] then
        print("[zhpunc] warning: category \'" .. class_name
            .. "\' 尚未用 \\definepuncs 定义，字符将无默认行为")
    end
    
    for _, char in ipairs(chars) do
        if class_props.punc ~= false then
            thirddata.zhpunc.user_char_class[char] = target_class
        else
            thirddata.zhpunc.user_char_class[char] = nil
        end
        
        -- 应用类别的凸排、禁排属性
        if class_props.protrude_left ~= nil then
            thirddata.zhpunc.user_protrude_left[char] = class_props.protrude_left
        end
        if class_props.protrude_right ~= nil then
            thirddata.zhpunc.user_protrude_right[char] = class_props.protrude_right
        end
        if class_props.forbid_start ~= nil then
            thirddata.zhpunc.user_forbid_start[char] = class_props.forbid_start
        end
        if class_props.forbid_end ~= nil then
            thirddata.zhpunc.user_forbid_end[char] = class_props.forbid_end
        end
        if class_props.quad ~= nil then
            thirddata.zhpunc.user_quad[char] = class_props.quad
        end
        -- 类别的前、后加空以角数存档（C：与 model/全半角无关，始终生效）
        local us = thirddata.zhpunc.user_space[char] or {}
        if class_props.space_after and class_props.space_after > 0 then
            us.after = class_props.space_after
        end
        if class_props.space_before and class_props.space_before > 0 then
            us.before = class_props.space_before
        end
        if us.after or us.before then
            thirddata.zhpunc.user_space[char] = us
        end
    end

    clear_punc_cache()
end

-- 从类别移除符号
-- @chars_str: 符号字符串
-- 注意：puncs 也会被清除，这意味着符号将完全脱离标点处理系统
function thirddata.zhpunc.remove_from_class(chars_str)
    if not chars_str then
        print("[zhpunc] Error: chars are required")
        return
    end
    
    local chars = parse_chars(chars_str)
    local tables_to_clear = {
        thirddata.zhpunc.user_char_class,
        thirddata.zhpunc.user_hangjian,
        thirddata.zhpunc.user_rotate,
        thirddata.zhpunc.user_protrude_left,
        thirddata.zhpunc.user_protrude_right,
        thirddata.zhpunc.user_forbid_start,
        thirddata.zhpunc.user_forbid_end,
        thirddata.zhpunc.user_quad,
        thirddata.zhpunc.user_space,
        -- puncs,
        -- puncs_to_hangjian,
        -- puncs_to_rotate,
    }
    
    for _, char in ipairs(chars) do
        for _, tbl in ipairs(tables_to_clear) do
            tbl[char] = nil
        end
    end

    clear_punc_cache()
end

-- 设置符号的特殊行为
-- @chars_str: 符号字符串
-- @params: 参数字符串
function thirddata.zhpunc.setup_chars(chars_str, params)
    if not chars_str or not params then
        print("[zhpunc] Error: chars and params are required")
        return
    end

    local chars = parse_chars(chars_str)
    local parsed = utilities.parsers.settings_to_hash(params) or {}

    -- 循环外一次性解析（parsed 与 char 无关）
    local p = {
        class         = parsed.class and resolve_class(parsed.class) or nil,
        hangjian      = opt_bool(parsed.hangjian),
        rotate        = opt_bool(parsed.rotate),
        protrudeleft  = opt_bool(parsed.protrudeleft),
        protruderight = opt_bool(parsed.protruderight),
        forbidstart   = opt_bool(parsed.forbidstart),
        forbidend     = opt_bool(parsed.forbidend),
        quad          = tonumber(parsed.quad),
        spacebefore   = tonumber(parsed.spacebefore),
        spaceafter    = tonumber(parsed.spaceafter),
    }

    for _, char in ipairs(chars) do
        if p.class then
            thirddata.zhpunc.user_char_class[char] = p.class
        end
        if p.hangjian ~= nil then
            thirddata.zhpunc.user_hangjian[char] = p.hangjian
        end
        if p.rotate ~= nil then
            thirddata.zhpunc.user_rotate[char] = p.rotate
        end
        if p.protrudeleft ~= nil then
            thirddata.zhpunc.user_protrude_left[char] = p.protrudeleft
        end
        if p.protruderight ~= nil then
            thirddata.zhpunc.user_protrude_right[char] = p.protruderight
        end
        if p.forbidstart ~= nil then
            thirddata.zhpunc.user_forbid_start[char] = p.forbidstart
        end
        if p.forbidend ~= nil then
            thirddata.zhpunc.user_forbid_end[char] = p.forbidend
        end
        if p.quad ~= nil then
            thirddata.zhpunc.user_quad[char] = p.quad
            -- quad 参与 punc_data 的缓存数值，变更后使该字符的所有缓存失效
            for _, fc in next, thirddata.zhpunc.puncs_font do
                fc[char] = nil
            end
        end
        if p.spacebefore ~= nil or p.spaceafter ~= nil then
            local us = thirddata.zhpunc.user_space[char] or {}
            if p.spacebefore ~= nil then
                us.before = (p.spacebefore > 0) and p.spacebefore or nil
            end
            if p.spaceafter ~= nil then
                us.after = (p.spaceafter > 0) and p.spaceafter or nil
            end
            thirddata.zhpunc.user_space[char] =
                (us.before or us.after) and us or nil
        end
    end

    clear_punc_cache()
end

function thirddata.zhpunc.enable()
    thirddata.zhpunc.enabled = true
    clear_punc_cache()
end

function thirddata.zhpunc.disable()
    thirddata.zhpunc.enabled = false
    clear_punc_cache()
end

-- =========================================================
--   第一路：弹性 → scripts.handlers.hanzi.datasets.custom 字段
--   第二路：宽度 → tex.setglue("kanjiskip"/"xkanjiskip")
-- =========================================================
local dataset_keys = {
    -- CJK–CJK 弹性：stretch/shrink 直接控制 scrp-cjk 的 interchar 因子
    stretch               = "inter_char_stretch_factor",
    shrink                = "inter_char_shrink_factor",
    -- 以下保留，供纯 scrp-cjk 模式（width=0）使用
    intercharstretch      = "inter_char_stretch_factor",
    intercharshrink       = "inter_char_shrink_factor",
    intercharhalfstretch  = "inter_char_half_stretch_factor",
    intercharhalfshrink   = "inter_char_half_shrink_factor",
    intercharquarterstretch = "inter_char_quarter_stretch_factor",
    intercharquartershrink  = "inter_char_quarter_shrink_factor",
    intercharhangulpenalty  = "inter_char_hangul_penalty",
}

function zhpunc.setdataset(method, name, kv)
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
        end
    end

    -- 宽度：只存 em 值，不调 tex.setglue
    if kv.width ~= nil then
        d.fixed_kanji_width_em = tonumber(kv.width)
        templates_dirty = true
    end
    if kv.halfwidth ~= nil then
        d.fixed_xkanji_width_em = tonumber(kv.halfwidth)
        templates_dirty = true 
    end

    -- 伸缩：作为"因子"存储
    if kv.halfstretch ~= nil then
        d.fixed_xkanji_stretch_factor = tonumber(kv.halfstretch)
        templates_dirty = true
    end
    if kv.halfshrink ~= nil then
        d.fixed_xkanji_shrink_factor = tonumber(kv.halfshrink)
        templates_dirty = true
    end
end

-- 确保 hanzi.custom 存在；用户先定义时不覆盖
if not scripts.handlers.hanzi.datasets.custom then
    scripts.installdataset {
        method  = "hanzi",
        name    = "custom",
        dataset = {
            inter_char_shrink_factor          = 0.10,
            inter_char_stretch_factor         = 0.10,
            inter_char_half_shrink_factor     = 0.10,
            inter_char_half_stretch_factor    = 0.10,
            inter_char_quarter_shrink_factor  = 0.05,
            inter_char_quarter_stretch_factor = 0.05,
            inter_char_hangul_penalty         = 50,
        }
    }
end

function thirddata.zhpunc.debugglues(head)
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

return thirddata.zhpunc


