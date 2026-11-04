-- =====================================================================
-- t-basicexam.lua
-- =====================================================================

thirddata = thirddata or {}
thirddata.basicexam = thirddata.basicexam or {}
local BEM = thirddata.basicexam

local DATA_VERSION = 0.3

-- level: "info" | "error" | "warning"
--   info    — 仅 check 模式输出，带缩进（树形日志）
--   error   — 任何模式都输出，不带缩进
--   warning — 任何模式都输出，不带缩进

BEM.log_indent = 0

local _reporters  = {}
local LEVEL_WIDTH = 7
local CHECK_LEVELS = { info = true, meta = true }

local function get_reporter(level)
  local fn = _reporters[level]
  if not fn then
    local pad   = math.max(0, LEVEL_WIDTH - #level)
    fn = logs.reporter("basicexam", level .. string.rep(" ", pad))
    _reporters[level] = fn
  end
  return fn
end

local function indent_prefix()
  if BEM.log_indent <= 0 then return "" end
  return string.rep("| ", BEM.log_indent - 1) .. "| "
end

local function report(level, fmt, ...)
  if CHECK_LEVELS[level] and not BEM.check_mode then return end

  local fn = get_reporter(level)
  local p  = (level == "info") and indent_prefix() or ""

  if p == "" then
    fn(fmt, ...)
  else
    fn("%s" .. fmt, p, ...)
  end
end

function BEM.enable_check()
  BEM.check_mode = true
end

BEM.check_mode         = false
BEM.partio_enabled     = true
BEM.data_loaded        = false

BEM.partio_serial = 0
BEM.answer_tree   = nil
BEM.current_node  = nil
BEM.segment_index = nil
BEM.current_partio_idx = nil

BEM.data               = {}
BEM.data_new           = {}
BEM.node_index         = {}
BEM.level_stack        = {}
BEM.replay_queue       = {}
BEM.collected_uids     = {}
BEM.chapter_counters   = {}
BEM.collected_groups   = {}
BEM.collected_segments = {}
BEM.partio_data        = {}     -- 上一遍编译加载的
BEM.partio_data_new    = {}     -- 本遍编译收集的

BEM.filter_meta   = BEM.filter_meta or {} -- 跨编译累积的筛选元信息：uid -> {tag, year}

local cached_jobname
local cached_chapter = nil
local cached_sectiondata = nil
local last_order_chapter = nil
local _typegrade_warned = {}

local fp_tobesaved = {
    missing           = "yes",
    write_error       = "no",
    fingerprint_error = "no",
    current           = "0",
}

-- 遗漏答案/分数 的代码表：env_type -> { code, name }
-- 图例按首次出现顺序只打一次，明细条目只带代码前缀
local MISSING_DEFAULT = { code = 200, name = "答案或分数" }

local MISSING_INFO = {
  question    = { code = 201, name = "question 答案或分数" },
  subquestion = { code = 202, name = "subquestion 答案或分数" },
  writing     = { code = 203, name = "writing 答案或分数" },
  pitem       = { code = 204, name = "pitem 答案或分数" },
  closechoice = { code = 205, name = "closechoice 答案或分数" },
}

job.register("basicexam.fingerprint", fp_tobesaved, nil, nil)

-- =====================================================================
-- 1. 私有数据文件
-- =====================================================================
-- 数据文件与 dataset 的 .tuc 一样，使用相对当前工作目录的文件名。

local function get_jobname()
  if cached_jobname then return cached_jobname end
  local j = token.getexpansion("\\jobname")
  if j and j ~= "" then
    cached_jobname = j
    return j
  end
  return "unknown"
end

function BEM.data_filename()
  return get_jobname() .. "-examdata.lua"
end

-- 只加载上一次编译的数据，供本次编译读取；本次写入放在 data_new。
-- 这样旧题目即使从文档中删除，也不会因为“整表回写”而残留。
function BEM.load_data()
  if BEM.data_loaded then return end
  BEM.data_loaded = true

  local filename = BEM.data_filename()
  local loaded = table.load(filename)
  
  local function invalidate(fmt, ...)
    BEM.data = {}
    BEM.partio_data = {}
    BEM.filter_meta = {}
    fp_tobesaved["missing"] = "yes"
    if fmt then report("warning", fmt, ...) end
  end

  if type(loaded) ~= "table" then
    invalidate()
    return
  end

  local meta    = loaded.__meta
  local records = loaded.__records

  if type(meta) ~= "table" or type(records) ~= "table" then
    invalidate("%s 不是当前数据格式，已丢弃；请重新编译一次", filename)
    return
  end

  if meta.version ~= DATA_VERSION then
    invalidate("%s 的数据版本为 %s，期望 %d，已丢弃；请重新编译一次",
      filename, tostring(meta.version), DATA_VERSION)
    return
  end

  if meta.jobname and meta.jobname ~= get_jobname() then
    invalidate("%s 属于文档 %s，与当前 %s 不符，已忽略",
      filename, meta.jobname, get_jobname())
    return
  end
  
  fp_tobesaved["missing"] = "no"

  local data = {}
  for tag, record in pairs(records) do
    if type(record) == "table" then
      data[tag] = record
    end
  end
  
  BEM.data = data
  BEM.partio_data = loaded.__partios or {}

  -- 本次编译的 segment_index / collected_segments 从空开始
  BEM.segment_index      = {}
  BEM.collected_segments = {}

  -- 读取筛选元信息（独立表，跨编译累积，只增不减）
  BEM.filter_meta = loaded.__filter_meta or {}

  BEM.data_uid_index = {}
  for id, rec in pairs(data) do
    if type(rec) == "table" and rec.uid and rec.uid ~= "" then
      BEM.data_uid_index[rec.uid] = id
    end
  end
end

-- =====================================================================
-- 2. 层级树 / 答案树
-- =====================================================================
-- 递归序列化：表按字母序排 key，数字 key 在前，2 空格缩进
local function ser(v, ind)
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  end
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format("%d", v)
    end
    return tostring(v)
  end
  if t == "boolean" then
    return tostring(v)
  end
  if t ~= "table" then
    return "nil"
  end

  local keys = {}
  for k in pairs(v) do keys[#keys+1] = k end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then return type(a) == "number" end
    return a < b
  end)

  local lines = { "{" }
  for _, k in ipairs(keys) do
    local ks = type(k) == "string"
      and string.format("[%q]", k)
      or  ("[" .. tostring(k) .. "]")
    lines[#lines+1] = ind .. "  " .. ks .. "=" .. ser(v[k], ind .. "  ") .. ","
  end
  lines[#lines+1] = ind .. "}"
  return table.concat(lines, "\n")
end

local function save_ordered(out, target)
  local order = { "__meta", "__filter_meta", "__partios", "__records" }
  local lines = { "return {" }
  for _, k in ipairs(order) do
    if out[k] ~= nil then
      lines[#lines+1] = string.format("  [%q]=", k) .. ser(out[k], "  ") .. ","
    end
  end
  lines[#lines+1] = "}"
  local content = table.concat(lines, "\n")

  if BEM.check_mode then
    local chunk, err = load(content, "=save_ordered", "t", {})
    if not chunk then
      _report("ERROR: save_ordered: %s", tostring(err))
      return false, "syntax error"
    end
  end

  local f = io.open(target, "w")
  if not f then return false, "cannot open " .. target end
  f:write(content)
  f:close()
  return true
end

local function resolve_data_id(id)
  if not id or id == "" then return id end
  if BEM.data and BEM.data[id] then return id end
  if BEM.data_uid_index and BEM.data_uid_index[id] then
    return BEM.data_uid_index[id]
  end
  return id
end

function BEM.setdata(settings)
  local name = settings.name
  local tag = settings.tag
  local data = settings.data
  if name ~= "ExamDataset" then return end

  if tag == "__meta" or tag == "__records" then
    report("warning", "setdata 拒绝保留键 %s", tag)
    return
  end

  if type(data) ~= "table" then data = {data = data} end
  if not tag then
    tag = #BEM.data_new + 1
  else
    tag = tonumber(tag) or tag
  end
  BEM.data_new[tag] = data
  return name, tag, data
end

function BEM.getdata(name, tag, key, default)
  if name and name ~= "ExamDataset" then return default end

  local record = BEM.data[tag] or BEM.data[tonumber(tag)]
  if not record then return default end

  if key then return record[key] or default end
  return record
end

function BEM.save_data()
  -- ① 本次收集的题目源码合并进 records
  if BEM.segment_index then
    for _, rec in pairs(BEM.data_new) do
      if type(rec) == "table" and rec.uid and rec.uid ~= "" then
        local s = BEM.segment_index[rec.uid]
        if s then
          rec.text   = s.text
          rec.buffer = s.buffer
          rec.seq    = s.seq
        end
      end
    end
  end

  -- ② 累积筛选元信息（跨编译保留，只增不减）
  -- 累积筛选元信息：迁移 data_new 里除大字段外的所有 key
  -- 注意： order 这种经常变化的字段也不要进入，避免产生多轮编译！
  local SKIP = {
    text = true, buffer = true, seq = true,
    id = true, number = true, answer = true,
    availablecolumns = true, order = true,
    depth = true, totalnumber = true,
  }
  BEM.filter_meta = BEM.filter_meta or {}
  for _, rec in pairs(BEM.data_new) do
    if type(rec) == "table" and rec.uid then
      local m = BEM.filter_meta[rec.uid] or {}
      for k, v in pairs(rec) do
        if k ~= "uid" and not SKIP[k] then m[k] = v end
      end
      BEM.filter_meta[rec.uid] = m
    end
  end

  local target = BEM.data_filename()

  if next(BEM.data_new) == nil then
    local f = io.open(target, "rb")
    if f then
      f:close()
      local ok = os.remove(target)
      if ok then
        report("info", "No exam records, removed stale data file %s", target)
      else
        report("warning", "No exam records, failed to remove stale data file %s", target)
      end
    end
    fp_tobesaved["missing"]            = "yes"
    fp_tobesaved["write_error"]        = "no"
    fp_tobesaved["fingerprint_error"]  = "no"
    fp_tobesaved["current"]            = "0"
    return false
  end

  local out = {
    __meta = {
      version        = DATA_VERSION,
      jobname        = get_jobname(),
      format         = "cont-en",
      module_version = "2026-10-30",
      created        = os.date("%Y-%m-%d"),
      -- 不要以秒或者分钟计数，会导致编译快速失效
    },
    __records     = BEM.data_new,
    __partios     = BEM.partio_data_new,
    __filter_meta = BEM.filter_meta,
    -- _filter_meta 存在的唯一理由就是“__records 会被覆盖，需要一个只增不减的副本”。
  }

  local ok, err = pcall(save_ordered, out, target)
  if not ok then
    report("error", "无法写入 %s: %s", target, err)
    fp_tobesaved["write_error"] = "yes"
    return false
  end
  fp_tobesaved["write_error"] = "no"

  local f = io.open(target, "rb")
  if not f then
    report("error", "无法读取 %s 计算指纹", target)
    fp_tobesaved["fingerprint_error"] = "yes"
    return false
  end
  fp_tobesaved["fingerprint_error"] = "no"

  local content = f:read("*a")
  f:close()

  local h = 5381
  for i = 1, #content do
    h = (h * 33 + content:byte(i)) & 0x7FFFFFFF
  end
  fp_tobesaved["missing"] = "no"
  fp_tobesaved["current"] = tostring(h)
  return true
end

function BEM.tex_get_data(tag, key)
  local real = resolve_data_id(tag)
  local v = BEM.getdata("ExamDataset", real, key)
  if v ~= nil and type(v) ~= "table" then
    context(tostring(v))
  end
end

local function get_current_chapter()
  local sectiondata = structures.sections.current()
  if sectiondata == cached_sectiondata then
    return cached_chapter or 0
  end
  cached_sectiondata = sectiondata
  if sectiondata and sectiondata.numberdata and sectiondata.numberdata.numbers then
    local numbers = sectiondata.numberdata.numbers
    local chapter = numbers[2] or numbers[1]
    cached_chapter = tonumber(chapter) or 0
  else
    cached_chapter = 0
  end
  return cached_chapter
end

local function get_chapter_counter(chapter)
  if not BEM.chapter_counters[chapter] then
    BEM.chapter_counters[chapter] = 0
  end
  BEM.chapter_counters[chapter] = BEM.chapter_counters[chapter] + 1
  return BEM.chapter_counters[chapter]
end

--[[
创建新节点
参数:
  id - 节点ID
  env_type - 环境类型 (question, subquestion 等)
  depth - 层级深度
  parent - 父节点引用
返回: 新创建的节点表
]]
local function create_node(id, env_type, depth, parent)
  local node = {
    id = id or "unknown", 
    env_type = env_type or "unknown", 
    depth = depth, parent = parent,
    children = {}, 
    totalnumber = 0, 
    totalpoint = 0, 
    currentpoint = 0,
    answer = "", 
    order = "", 
    is_leaf = false, 
    child_counter = 0,
    extra_data = {},
    number = id and (id:match("%-Q%-(%d+)") or id:match("Q%-(%d+)") or "") or "",
  }
  if id then BEM.node_index[id] = node end
  return node
end

--[[
初始化答案树: 创建根节点并设置当前节点为根
]]
function BEM.init_tree()
  BEM.node_index = {}
  BEM.uid_index  = {}
  BEM.answer_tree = create_node("root", "root", 0, nil)
  BEM.answer_tree.is_leaf = false
  BEM.current_node = BEM.answer_tree
  BEM.level_stack = {BEM.answer_tree}
  BEM.chapter_counters = {}
  BEM.citem_count = 0
  last_order_chapter = nil
  cached_sectiondata = nil
  cached_chapter = nil
  cached_jobname = nil
  report("info", "Tree initialized")
end

--[[
生成层级ID: 根据父节点ID和子节点计数器生成唯一ID
格式: 文件名-章节-Q-N 或 文件名-章节-Q-N-M
返回: 生成的ID字符串
]]
local function generate_level_id(parent)
  if not parent or parent.id == "root" then
    local chapter = get_current_chapter()
    local counter = get_chapter_counter(chapter)
    return string.format("%s-%d-Q-%d", get_jobname() or "unknown", chapter, counter)
  end
  parent.child_counter = parent.child_counter + 1
  return string.format("%s-%d", parent.id, parent.child_counter)
end

--[[
更新所有祖先节点的统计信息
参数:
  node - 起始节点
  delta_point - 分数变化量
  delta_number - 题目数量变化量
]]
local function update_ancestors(node, delta_point, delta_number)
  while node do
    node.totalpoint = node.totalpoint + delta_point
    node.totalnumber = node.totalnumber + delta_number
    node = node.parent
  end
end

--[[
收集节点下所有叶子节点的答案
参数: node - 目标节点
返回: 答案字符串，用 "; " 分隔
]]
local function collect_leaf_answers(node)
  local answers = {}
  local function collect(n)
    if n.is_leaf and n.answer ~= "" then table.insert(answers, n.answer) end
    for _, c in ipairs(n.children) do collect(c) end
  end
  collect(node)
  return #answers > 0 and table.concat(answers, "; ") or ""
end

--[[
统一节点 answer 的取值口径：
  叶子   -> 自己的答案
  非叶子 -> 子树所有叶子答案的拼接
这样私有数据文件和 TSV 导出使用同一份逻辑，不会再出现不一致。
]]
local function get_node_answer(node)
  if node.is_leaf then
    return node.answer or ""
  end
  return collect_leaf_answers(node)
end

--[[
构造单个节点的持久化记录。
运行期不再逐节点写入 data_new，而是在 finalize_check 时统一遍历生成。
]]
local function build_node_record(node)
  local data = {
    id          = node.id, 
    env         = node.env_type,
    depth       = node.depth, 
    order       = node.order or "",
    number      = node.number or "",
    answer      = get_node_answer(node),
    point       = node.totalpoint, 
    totalnumber = node.totalnumber,
  }
  for k, v in pairs(node.extra_data) do data[k] = v end
  -- 无选项的节点也写入这些键，避免出现 "tag 存在而 key 缺失" 的状态
  if data.availablecolumns == nil then data.availablecolumns = "0" end
  return data
end

--[[
遍历一次答案树，生成所有节点记录。
返回按树顺序排列的记录列表，供 TSV 导出复用。
]]
function BEM.build_node_data()
  local records = {}
  local missing = {}

  local function collect(node)
    if not node then return end
    if node.depth > 0 then
      local data = build_node_record(node)
      BEM.data_new[node.id] = data
      records[#records + 1] = data

      -- 顺带检查：有环境但既无答案也无分数的叶子
      if node.is_leaf and #node.children == 0
         and (node.answer == nil or node.answer == "")
         and (node.currentpoint or 0) == 0 then
        missing[#missing + 1] = node
      end
    end
    for _, child in ipairs(node.children) do collect(child) end
  end

  collect(BEM.answer_tree)

  if #missing > 0 then
    -- 按代码去重，图例只打一次；顺序 = 首次出现顺序
    local seen_code = {}
    local legend    = {}
    for _, node in ipairs(missing) do
      local info = MISSING_INFO[node.env_type] or MISSING_DEFAULT
      if not seen_code[info.code] then
        seen_code[info.code] = true
        legend[#legend + 1]  = info
      end
    end

    -- 图例
    for _, info in ipairs(legend) do
      report("warning", "%d = 遗漏 %s", info.code, info.name)
    end

    -- 明细
    for _, node in ipairs(missing) do
      local info = MISSING_INFO[node.env_type] or MISSING_DEFAULT
      report("warning", "  %d: ID=%s，层级=%d",
        info.code, node.id, node.depth)
    end
  end

  return records
end

--[[
设置当前节点的额外数据
TeX接口: UnlimitedSetExtraData(key, value)
参数:
  key - 数据键名
  value - 数据值
功能: 为当前节点存储额外的元数据（如选择题排版信息）
]]
function BEM.set_extra_data(key, value)
  if BEM.current_node then
    BEM.current_node.extra_data[key] = value

    -- 新增：登记 uid → node.id，支持通过 uid 查找
    if key == "uid" and value ~= "" then
      BEM.uid_index = BEM.uid_index or {}
      local existing = BEM.uid_index[value]
      if existing and existing ~= BEM.current_node.id then
        report("warning", "重复的 uid '%s'：已存在 %s，新节点 %s",
          value, existing, BEM.current_node.id)
      else
        BEM.uid_index[value] = BEM.current_node.id
      end
    end

    if BEM.check_mode then
      report("info", "Set extra data: %s = %s", key, tostring(value))
    end
  end
end

function BEM.set_extra_data_list(ns, keys)
  if not BEM.current_node or ns == "" then return end
  for k in keys:gmatch("[^,%s]+") do
    local v = token.getexpansion("\\" .. ns .. "parameter{" .. k .. "}")
    if k == "uid" and v == "" and BEM.current_node.depth == 1 then
      local uid = table.remove(BEM.replay_queue or {}, 1)
      if uid then v = uid end
    end
    if v ~= "" then
      BEM.current_node.extra_data[k] = v

      if k == "uid" then
        BEM.uid_index = BEM.uid_index or {}
        local existing = BEM.uid_index[v]
        if existing and existing ~= BEM.current_node.id then
          report("warning", "重复的 uid '%s'：已存在 %s，新节点 %s",
            v, existing, BEM.current_node.id)
        else
          BEM.uid_index[v] = BEM.current_node.id
        end
      end

      if BEM.check_mode then
        report("info", "Set extra data: %s = %s", k, v)
      end
    end
  end
end

--[[
进入新层级
TeX接口: UnlimitedPushLevel(env_type)
参数: env_type - 环境类型
功能: 创建新节点并设为当前节点，同时维护环境栈用于嵌套检查
]]
function BEM.push_level(env_type)
  if not BEM.answer_tree then BEM.init_tree() end
  local parent = BEM.current_node

  BEM.citem_count = 0

  if parent.is_leaf then
    local pt = parent.currentpoint
    parent.is_leaf, parent.currentpoint, parent.answer = false, 0, ""
    -- 祖先中移除该叶子的旧贡献
    if parent.parent then update_ancestors(parent.parent, -pt, -1) end
    parent.totalpoint, parent.totalnumber = 0, 0
  end

  local new_node = create_node(generate_level_id(parent), env_type, parent.depth + 1, parent)
  local tex_number = token.getexpansion("\\rawcountervalue[currentexamorder]")
  if parent.id == "root" then
    -- 顶层大题：直接使用 TeX 的 currentexamorder
    new_node.order = (tex_number and tex_number ~= "") and tex_number or "0"
  else
    -- 子题（包括普通 subquestion 和 continue=no 的完形填空）：拼装父题号
    parent.order_counter = (parent.order_counter or 0) + 1
    new_node.order = (parent.order or "") .. "-" .. tostring(parent.order_counter)
  end
  table.insert(parent.children, new_node)
  BEM.current_node = new_node
  table.insert(BEM.level_stack, new_node)

  if new_node.depth == 1 then
    BEM.partio_register(new_node.id) 
    -- 顶层题目：整条横线 + 题头
    report("info", "┌─%s", string.rep("─", 76))
    report("info", "▣ Q%s [%s]", new_node.order, env_type)
    BEM.log_indent = 1
  else
    -- 嵌套子题：先画 ┌─ （此时 log_indent 仍是旧值，缩进正确），再升高
    report("info", "┌─ L%d [%s]  %s", new_node.depth, env_type, new_node.id)
    BEM.log_indent = BEM.log_indent + 1
  end
  
  report("info", "Pushed level %d: %s (%s), order=%s",
    new_node.depth, new_node.id, env_type, new_node.order)
end

--[[
添加带分数的答案
TeX接口: UnlimitedAddScoredAnswer(answer, point)
参数:
  answer - 答案内容
  point - 分数
功能: 为当前节点设置答案和分数，并更新祖先节点统计
]]
function BEM.add_scored_answer(answer, point)
  local n = BEM.current_node
  if not n or #n.children > 0 then return end
  if n.depth == 0 then
    report("error", "不能在根节点添加答案")
    return
  end

  local is_first_time = not n.is_leaf
  if n.is_leaf then
    local old_pt = n.currentpoint
    n.currentpoint, n.answer = 0, ""
    update_ancestors(n, -old_pt, 0)
  end

  local pt = tonumber(point) or 0
  n.answer, n.currentpoint, n.is_leaf = answer or "", pt, true
  update_ancestors(n, pt, is_first_time and 1 or 0)
  report("info", "Added answer: %s, point=%.1f",
    (answer ~= "" and answer) or '""', pt)
end

--[[
退出当前层级
TeX接口: UnlimitedPopLevel() 或 UnlimitedPopLevelChecked(env_type)
参数: env_type - (可选) 期望的环境类型，提供时会检查环境名称是否匹配
功能: 返回到父节点，如果当前节点有子节点则标记为非叶子
]]
function BEM.pop_level(env_type)
  if #BEM.level_stack <= 1 then
    if env_type then
      report("error",   "多余的 \\stop%s，无对应 \\start%s", env_type, env_type)
    end
    return
  end
  
  if env_type then
    local current_env = BEM.current_node.env_type
    if current_env ~= env_type then
      report("error",   "禁止跨层闭合！当前最内层未闭合环境：%s，你试图提前闭合环境：%s",
        current_env, env_type)
      return
    end
  end
  
  local node = BEM.current_node

  if #node.children > 0 and node.is_leaf then
    local pt = node.currentpoint
    node.is_leaf = false
    node.currentpoint = 0
    node.answer = ""
    
    local new_total, new_num = 0, 0
    for _, child in ipairs(node.children) do
      new_total = new_total + child.totalpoint
      new_num = new_num + child.totalnumber
    end
    node.totalpoint = new_total
    node.totalnumber = new_num
    
    if node.parent then
      update_ancestors(node.parent, -pt, -1)
    end
    report("info",  "Node recalculated: %.1f -> %.1f", pt, new_total)
  end
  
  table.remove(BEM.level_stack)

  if node.depth == 1 then
      report("info",  "Popped to level 0")
      BEM.log_indent = 0
      report("info",  "└%s", string.rep("─", 76))
      report("info",  "  Q%s done  | total=%.1f  | leaf=%d",
        node.order, node.totalpoint, node.totalnumber)
    else
      report("info",  "Popped to level %d", BEM.current_node.depth)
      BEM.log_indent = BEM.log_indent - 1
      report("info",  "└─ L%d [%s] done", node.depth, node.env_type)
    end

    BEM.current_node = BEM.level_stack[#BEM.level_stack]
end

--[[
检查是否有未闭合的环境
TeX接口: UnlimitedCheckUnclosed()
功能: 在文档结束时检查是否有未闭合的环境
]]
function BEM.check_unclosed()
  if #BEM.level_stack > 1 then
    local unclosed_count = #BEM.level_stack - 1
    report("error", "剩余 %d 层环境未闭合", unclosed_count)
    for i = 2, #BEM.level_stack do
      local node = BEM.level_stack[i]
      report("error", "  未闭合: %s (层级 %d)", node.env_type, node.depth)
    end
  end
end

--[[
查找节点 by ID
参数: id - 节点ID
返回: 节点表或nil
]]
function BEM.find_node_by_id(id)
  if not id or id == "" then return nil end
  local node = BEM.node_index and BEM.node_index[id]
  if node then return node end
  -- 并行路径：按 uid 查
  if BEM.uid_index then
    local real_id = BEM.uid_index[id]
    if real_id then return BEM.node_index[real_id] end
  end
  return nil
end

--[[
获取节点的显示信息(只做信息返回)
TeX接口: UnlimitedDisplayPoint(id), UnlimitedDisplayAnswer(id) 等
参数: id - 节点ID
返回: {point, answer, is_leaf, totalnumber}
]]
function BEM.get_display(id)
  local node = BEM.find_node_by_id(id)
  if not node then
    return {point = 0, answer = "", is_leaf = false, order = ""}
  end
  return {
    point       = node.totalpoint,
    answer      = get_node_answer(node),
    is_leaf     = node.is_leaf,
    totalnumber = node.totalnumber,
    order       = node.order or "",
  }
end

--[[
TeX输出接口(输出到TEX)
参数:
  id - 节点ID
  key - 要获取的属性 (point/answer/is_leaf/totalnumber)
]]
function BEM.tex_get(id, key)
  local d = BEM.get_display(id)
  if key == "point" then
    local p = d.point
    context(p == math.floor(p) and p or string.format("%.1f", p))
  elseif key == "answer" then context(d.answer)
  elseif key == "is_leaf" then context(d.is_leaf and "true" or "false")
  elseif key == "totalnumber" then context(d.totalnumber or 0)
  elseif key == "order" then context(d.order or "")
  end
end

--[[
  一次性计算所有章节的统计信息（唯一数据源）
  返回: { chapter_num -> {totalnumber, totalpoint, leafnumber, allleafnumber} }
  口径说明:
    totalnumber   — 该章节下顶层题目数（answer_tree 的直接子节点）
    totalpoint    — 该章节下顶层题目总分
    leafnumber    — 该章节下「本身就是叶子」的顶层题目数
    allleafnumber — 该章节子树中所有叶子节点数（实际小题数）
  实现要点:
    answer_tree.children 就是顶层题目，ID 形如 jobname-chapter-Q-N。
    只要遍历这一层 + 对每个顶层节点递归统计叶子，即可覆盖整章。
    不需要遍历整棵 answer_tree，也不需要 prefix 过滤。
]]
local function compute_chapter_stats()
  local result = {}
  if not BEM.answer_tree then return result end

  -- 统计某节点子树下的叶子数
  local function count_leaves(node, s)
    if node.is_leaf then
      s.allleafnumber = s.allleafnumber + 1
    end
    for _, c in ipairs(node.children) do
      count_leaves(c, s)
    end
  end

  for _, top in ipairs(BEM.answer_tree.children) do
    local chapter_num = tonumber(top.id:match("%-(%d+)%-Q%-")) or 0

    local s = result[chapter_num]
    if not s then
      s = {totalnumber = 0, totalpoint = 0, leafnumber = 0, allleafnumber = 0}
      result[chapter_num] = s
    end

    s.totalnumber = s.totalnumber + 1
    s.totalpoint  = s.totalpoint  + (top.totalpoint or 0)
    if top.is_leaf then
      s.leafnumber = s.leafnumber + 1
    end

    count_leaves(top, s)
  end

  return result
end

--[[
  获取指定 structure level 的统计信息
  参数:
    level  - structure level (目前只实现 1 = chapter)
    number - 该层级的编号
  返回: {totalnumber, totalpoint, leafnumber, allleafnumber}
  实现:
    优先读私有数据文件缓存（由上一次编译的 save_structure_data 写入）；
    未命中时从当前 answer_tree 实时计算章节统计。
  注意:
    目前只实现 level=1（chapter）的统计。level≠1 会返回零并给出 warning，
    避免像旧版那样静默返回「chapter 1 的统计」当作 section 1 的统计。
]]
function BEM.get_structure_stats(level, number)
  local jobname = get_jobname() or "unknown"
  local tag = string.format("StructureStats-%s-L%d-%d", jobname, level, number)
  local cached = BEM.getdata("ExamDataset", tag)

  if cached and cached.totalnumber then
    report("info", "Retrieved structure stats from cache: %s -> totalnumber=%s, totalpoint=%s",
      tag, cached.totalnumber, cached.totalpoint)
    return {
      totalnumber   = cached.totalnumber,
      totalpoint    = cached.totalpoint,
      leafnumber    = cached.leafnumber or 0,
      allleafnumber = cached.allleafnumber or 0,
    }
  end

  -- 只实现 level=1；其他 level 返回零，避免静默错误
  if level ~= 1 then
    report("warning", "structure stats for level=%s not implemented, returning zeros", level)
    return {totalnumber = 0, totalpoint = 0, leafnumber = 0, allleafnumber = 0}
  end

  report("info", "Calculating structure stats (no cache): level=1, number=%s", number)
  local all = compute_chapter_stats()
  return all[number]
      or {totalnumber = 0, totalpoint = 0, leafnumber = 0, allleafnumber = 0}
end

--[[
获取当前 structure 的统计信息
参数: level - structure level (1=chapter, 2=section, etc.)
返回: {totalnumber, totalpoint, leafnumber, allleafnumber}
]]
function BEM.get_current_structure_stats(level)
  local sectiondata = structures.sections.current()
  if sectiondata
    and sectiondata.numberdata
    and sectiondata.numberdata.numbers then
    local numbers = sectiondata.numberdata.numbers
    -- numbers: 1=part, 2=chapter, 3=section, ...
    local number = numbers[level + 1] or numbers[2] or numbers[1]
    if number then
      return BEM.get_structure_stats(level, tonumber(number) or 0)
    end
  end
  return {totalnumber = 0, totalpoint = 0, leafnumber = 0, allleafnumber = 0}
end

--[[
TeX接口: 获取 structure 统计
参数:
  level - structure level (1=chapter, 2=section) level=2 尚未实现
  number - 该层级的编号 (可选，不提供则使用当前 structure)
  key - 要获取的属性 (totalnumber/totalpoint/leafnumber/allleafnumber)
]]
function BEM.tex_get_structure(level, number, key)
  local stats
  if number and number ~= "" then
    stats = BEM.get_structure_stats(tonumber(level) or 1, tonumber(number) or 0)
  else
    stats = BEM.get_current_structure_stats(tonumber(level) or 1)
  end
  report("info", "Structure stats (level=%s, number=%s): totalnumber=%s, totalpoint=%s, leafnumber=%s, allleafnumber=%s",
    level, number or "current", stats.totalnumber, stats.totalpoint, stats.leafnumber, stats.allleafnumber)
  if key == "totalnumber" then context(stats.totalnumber)
  elseif key == "totalpoint" then context(stats.totalpoint)
  elseif key == "leafnumber" then context(stats.leafnumber)
  elseif key == "allleafnumber" then context(stats.allleafnumber)
  end
end

--[[
获取指定题目的层级统计信息
参数: id - 题目ID
返回: {levelcounts, leafnumber, totalpoint}
  levelcounts: 表，键为层级深度，值为该层级的题目数量
  leafnumber: 所有叶子节点数量
  totalpoint: 总分
]]
function BEM.get_question_level_stats(id)
  local node = BEM.find_node_by_id(id)
  if not node then
    return {levelcounts = {}, leafnumber = 0, totalpoint = 0}
  end

  local stats = {
    levelcounts = {},
    -- 自己是叶子就算 1，否则由下面的递归统计子题叶子
    leafnumber  = node.is_leaf and 1 or 0,
    totalpoint  = node.totalpoint or 0,
  }

  if not node.is_leaf then
    local function count_by_level(n, relative_depth)
      for _, child in ipairs(n.children) do
        local depth = relative_depth + 1
        stats.levelcounts[depth] = (stats.levelcounts[depth] or 0) + 1
        if child.is_leaf then
          stats.leafnumber = stats.leafnumber + 1
        end
        count_by_level(child, depth)
      end
    end
    count_by_level(node, 0)
  end

  return stats
end

--[[
TeX接口: 获取题目层级统计
参数:
  id - 题目ID
  key - 要获取的属性 (levelN/leafnumber/totalpoint)
]]
function BEM.tex_get_question_level(id, key)
  local stats = BEM.get_question_level_stats(id)
  
  if key:find("^level%d+$") then
    local depth = tonumber(key:match("level(%d+)"))
    context(stats.levelcounts[depth] or 0)
  elseif key == "leafnumber" then
    context(stats.leafnumber)
  elseif key == "totalpoint" then
    context(stats.totalpoint)
  end
end

--[[
获取当前深度
TeX接口: UnlimitedDepth()
返回: 当前层级深度 (0=根)
]]
function BEM.get_depth() return BEM.current_node and BEM.current_node.depth or 0 end

--[[
获取当前节点ID
TeX接口: UnlimitedCurrentID()
返回: 当前节点ID字符串
]]
function BEM.get_current_id() return BEM.current_node and BEM.current_node.id or "" end

--[[
导出答案到TSV文件
参数:
  filename - 输出文件名
  records  - build_node_data() 返回的、按树顺序排列的节点记录
]]
local FRONT = { "id","depth","env","order","answer","point" }
local BACK  = { "totalnumber", "availablecolumns" }

local FRONT_SET, BACK_SET = {}, {}
for _, k in ipairs(FRONT) do FRONT_SET[k] = true end
for _, k in ipairs(BACK)  do BACK_SET[k]  = true end

local function collect_extra_keys(records)
  local seen, list = {}, {}
  for _, rec in ipairs(records or {}) do
    for k in pairs(rec) do
      if not FRONT_SET[k] and not BACK_SET[k] and k ~= "number" and not seen[k] then
        seen[k] = true
        list[#list + 1] = k
      end
    end
  end
  table.sort(list)   -- 用户键字母序
  return list
end

function BEM.export_answers(filename, records)
  local file = io.open(filename, "w")
  if not file then return report("error", "Cannot open %s", filename) end
  local T = string.char(9)
  local extra = collect_extra_keys(records)

  local cols = {}
  for _, k in ipairs(FRONT) do cols[#cols+1] = k end
  for _, k in ipairs(extra)  do cols[#cols+1] = k end
  for _, k in ipairs(BACK)   do cols[#cols+1] = k end

  file:write(table.concat(cols, T), "\n")

  for _, data in ipairs(records or {}) do
    local cells = {}
    for _, k in ipairs(cols) do
      local v = data[k]
      if k == "point" then
        cells[#cells+1] = string.format("%.1f", tonumber(v) or 0)
      else
        cells[#cells+1] = tostring(v or "")
      end
    end
    file:write(table.concat(cells, T), "\n")
  end
  file:close()
  report("info", "Exported to %s", filename)
end

--[[
  把当前章节统计写入私有数据文件，供下一次编译读取。
  只负责保存，统计逻辑全部委托给 compute_chapter_stats()。
]]
function BEM.save_structure_data()
  if not BEM.answer_tree then
    report("warning", "No answer tree, skipping structure stats save")
    return
  end

  local jobname = get_jobname() or "unknown"

  for chapter_num, stats in pairs(compute_chapter_stats()) do
    local tag = string.format("StructureStats-%s-L%d-%d", jobname, 1, chapter_num)
    BEM.setdata {
      name = "ExamDataset",
      tag  = tag,
      data = {
        level         = 1,
        number        = chapter_num,
        totalnumber   = stats.totalnumber,
        totalpoint    = stats.totalpoint,
        leafnumber    = stats.leafnumber,
        allleafnumber = stats.allleafnumber,
      }
    }
    report("info", "Saved structure stats: %s -> totalnumber=%s, totalpoint=%s, allleafnumber=%s",
      tag, stats.totalnumber, stats.totalpoint, stats.allleafnumber)
  end
end

function BEM.report_summary()
  local seed = utilities.randomizer.getseed() or 0
  local n = 0
  for _ in pairs(BEM.data_new or {}) do n = n + 1 end

  report("meta", "──────── 编译摘要 ────────")
  report("meta", "jobname       : %s", get_jobname() or "unknown")
  report("meta", "random seed   : %d", seed)
  report("meta", "partio serial : %d", BEM.partio_serial)
  report("meta", "data records  : %d", n)
  report("meta", "──────────────────────────")
end

function BEM.finalize_check()
  BEM.check_unclosed()

  -- 本次编译的数据写入只在这里发生一次：
  -- 清空 → 遍历树生成节点记录 → 补章节统计 → 补 partio 统计 → 落盘
  BEM.data_new = {}
  local records = BEM.build_node_data()

  BEM.save_structure_data()
  BEM.save_partio_data()
  BEM.save_data()

  if not BEM.check_mode then return end

  -- check 模式附加：导出 TSV + 打印摘要
  BEM.export_answers(get_jobname() .. "-answers.tsv", records)
  BEM.report_summary()
end

--[[
TeX接口: UnlimitedGetExtraNumber(id, key, default)
参数: id - 节点ID, key - 键名, default - 默认值
输出: 可解析为数字的值；否则输出 default
说明: 用于计数器赋值，保证任何脏缓存都只会退回默认值而不是中断编译。
]]
function BEM.tex_get_extra_number(id, key, default)
  local real = resolve_data_id(id)
  local v = BEM.getdata("ExamDataset", real, key)
  v = tonumber(v)
  context(tonumber(v or default) or 0)
end

function BEM.collect_answer_joined()
  local t = thirddata.basicexam.MultiAnswerCollector or {}
  local r = {}
  for i = 1, #t do
    r[i] = (t[i] or ""):match("^%s*(.-)%s*$") or ""
  end
  tex.sprint(table.concat(r, ","))
end

-- =====================================================================
-- 3. Partio 收集器：partio 只负责收集题目 id，不负责排版
-- =====================================================================

-- 稳定的字符串散列：同一份内容每次编译都得到同一个随机顺序
local function bem_hash(s)
  local h = 5381
  s = tostring(s or "")
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 2147483647
  end
  return h
end

-- 独立的 Fisher-Yates 洗牌，不污染全局 math.random 状态
local function bem_shuffle(t, seed)
  local state = seed % 2147483647
  if state <= 0 then
    state = 1
  end
  local function next_random()
    state = (state * 48271) % 2147483647
    return state
  end
  for i = #t, 2, -1 do
    local j = (next_random() % i) + 1
    t[i], t[j] = t[j], t[i]
  end
end

-- 统一的种子构造：
--   \jobname                         —— 文档身份（同一文档内可复现）
--   \setrandomseed/\setuprandomize   —— 全局随机源（choice 的 random、process、flush 共享）
--   附加串 (salt)                    —— 区分不同用途，避免同一置换被多处复用
-- 相同文档 + 相同 randomseed + 相同 salt → 同一条 seed，保证可复现
local function bem_seed(...)
  local parts = {
    get_jobname() or "unknown",
    string.format("%d", utilities.randomizer.getseed() or 0)
  }
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  return bem_hash(table.concat(parts, "\0"))
end

function BEM.partio_set_enabled(v)
  BEM.partio_enabled = (v == true or v == "true" or v == "yes" or v == "1")
end

function BEM.partio_begin(uid)
  BEM.partio_serial = BEM.partio_serial + 1
  local serial = BEM.partio_serial
  local p_id = "partio_" .. serial

  uid = (type(uid) == "string" and uid ~= "") and uid or nil
  if uid then
    -- uid 去重（跨本遍所有 partio）
    for _, p in pairs(BEM.partio_data_new) do
      if type(p) == "table" and p.uid == uid then
        report("warning", "Partio uid '%s' 已存在（%s），本次 uid 忽略",
          uid, p.id)
        uid = nil
        break
      end
    end
  end

  BEM.current_partio_idx = p_id
  local chapter = get_current_chapter()
  BEM.partio_data_new[p_id] = {
    id           = p_id,
    uid          = uid, 
    serial       = serial,
    chapter      = chapter,
    questionlist = {},
  }
  BEM.partio_enabled = true
  report("info", "Partio #%d begin (id=%s, uid=%s, chapter=%d)",
    serial, p_id, uid or "-", chapter)
end

function BEM.partio_register(id)
  if not BEM.partio_enabled then return end
  if not BEM.current_partio_idx then return end
  
  local p = BEM.partio_data_new[BEM.current_partio_idx]
  if not p then return end
  
  table.insert(p.questionlist, id)
  report("info", "Partio %s registers %s", BEM.current_partio_idx, id)
end

function BEM.save_partio_data()
  if not BEM.partio_data_new then return end

  for _, p in pairs(BEM.partio_data_new) do
    local p_point = 0
    local p_num = 0
    local p_leaves = 0
    local id_list = {} 

    for _, qid in ipairs(p.questionlist) do
      local rec = BEM.data_new[qid]
      if rec then
        id_list[#id_list + 1] = qid -- 只推入 ID
        
        p_point = p_point + (tonumber(rec.point) or 0)
        p_num = p_num + 1
        p_leaves = p_leaves + (tonumber(rec.totalnumber) or 0)
      end
    end

    p.questionlist = id_list
    p.point = p_point
    p.totalnumber = p_num
    p.allleafnumber = p_leaves
  end
end

-- =====================================================================
-- 4. 乱序
-- =====================================================================

-- 解析 filter：先保护 {...} 里的逗号，再按逗号切 key=value
local function parse_filter(filter)
  local prot = filter:gsub("({[^}]*})", function(m)
    return (m:gsub(",", "\1"))
  end)
  local parts = {}
  for pair in prot:gmatch("[^,]+") do
    local k, v = pair:match("^%s*(%w+)%s*=%s*(.-)%s*$")
    if k then
      v = v:gsub("\1", ",")
      parts[#parts + 1] = { key = k, value = v }
    end
  end
  return parts
end

-- 解析 value：A -> single；{A,B} -> or；{A+B} -> and
local function parse_value(v)
  local inner = v:match("^%s*{(.*)}%s*$")
  if not inner then
    return { mode = "single", items = { v:match("^%s*(.-)%s*$") } }
  end
  local sep = inner:find("+", 1, true) and "+" or ","
  local items = {}
  for t in inner:gmatch("[^" .. sep .. "]+") do
    local s = t:match("^%s*(.-)%s*$")
    if s ~= "" then items[#items + 1] = s end
  end
  return { mode = (sep == "+") and "and" or "or", items = items }
end

local function match_filter(meta, filter)
  for _, kv in ipairs(parse_filter(filter)) do
    local k, pv = kv.key, parse_value(kv.value)
    local mv = meta[k]
    if mv ~= nil then
      mv = tostring(mv)
      local mset = {}
      for t in mv:gmatch("[^,]+") do
        local s = t:match("^%s*(.-)%s*$")
        if s ~= "" then mset[s] = true end
      end
      local ok
      if pv.mode == "single" then
        ok = mset[pv.items[1]] == true
      elseif pv.mode == "or" then
        ok = false
        for _, v in ipairs(pv.items) do
          if mset[v] then ok = true; break end
        end
      else
        ok = true
        for _, v in ipairs(pv.items) do
          if not mset[v] then ok = false; break end
        end
      end
      if not ok then return false end
    end
  end
  return true
end

-- 按 bemseparator 切字符串，空段丢弃
local function split_by_separator(content)
  local segs = {}
  local sep = "\\bemseparator"
  local start = 1
  while true do
    local s, e = content:find(sep, start, true)
    if not s then
      local tail = content:sub(start):gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
      if tail:match("%S") then segs[#segs+1] = tail end
      break
    end
    local seg = content:sub(start, s - 1):gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
    if seg:match("%S") then segs[#segs+1] = seg end
    start = e + 1
  end
  return segs
end

function BEM.process_buffers(spec, filter)
  if not spec or spec == "" then
    report("warning", "empty buffer spec")
    return
  end

  local names = {}
  for n in spec:gmatch("[^,%s]+") do names[#names+1] = n end

  local seed = bem_seed("process", spec)

  -- 收集所有 buffer 的所有段
  local items = {}
  for _, name in ipairs(names) do
    local c = buffers.getcontent(name)
    if not c or c == "" then
      report("warning", "buffer '%s' is empty, skipped", name)
    else
      local segs = split_by_separator(c)
      for i, seg in ipairs(segs) do
        local uid = seg:match("uid=([%w_%-]+)")
        local auto = false
        if not uid then
          uid  = name .. "-uid-" .. i
          auto = true
        end
        items[#items+1] = { uid = uid, text = seg, buffer = name, auto = auto }
      end
    end
  end

  if #items == 0 then
    BEM.collected_segments = {}
    report("warning", "no non-empty segments in [%s]", spec)
    return
  end

  -- 冲突检测：只警告 + 推荐，不改任何数据
  local seen = {}
  for _, item in ipairs(items) do
    seen[item.uid] = seen[item.uid] or {}
    seen[item.uid][item.buffer] = true
  end

  local function suggest_uid(base)
    local n = 1
    while true do
      local c = base .. "_" .. n
      local taken_now  = seen[c] ~= nil
      local taken_hist = BEM.segment_index and BEM.segment_index[c] ~= nil
      if not taken_now and not taken_hist then return c end
      n = n + 1
    end
  end

  for uid, bufs in pairs(seen) do
    local list = {}
    for b in pairs(bufs) do list[#list+1] = b end
    table.sort(list)

    if #list > 1 then
      report("warning", "题目编号 '%s' 在 %s 里重复了。"
        .. "PDF 里会出现两道题，但数据文件只保留最后一道（后面的覆盖前面的）。"
        .. "请把其中一道改成 '%s'",
        uid, table.concat(list, " 和 "), suggest_uid(uid))
    end
  end

  -- 筛选（按 filter_meta，不解析 text）
  filter = filter and filter:match("^%s*(.-)%s*$") or ""
  if filter ~= "" then
    local has_meta = next(BEM.filter_meta or {}) ~= nil
    if not has_meta then
      report("warning", "首次编译没有历史元信息，忽略筛选 [%s]，回放全部。"
        .. "第二次编译起筛选生效。", filter)
      filter = ""
    else
      local kept = {}
      for _, item in ipairs(items) do
        local meta = BEM.filter_meta[item.uid]
        if meta and match_filter(meta, filter) then
          kept[#kept+1] = item
        else
          report("warning", "uid '%s' 无历史元信息或不符合筛选 [%s]，已跳过",
            item.uid, filter)
        end
      end
      items = kept
      if #items == 0 then
        report("warning", "筛选 [%s] 后无可回放题目", filter)
        BEM.collected_segments = {}
        return
      end
    end
  end

  -- 去重：同一 uid 在 place 之前只收录一次
  local deduped = {}
  for _, item in ipairs(items) do
    if BEM.collected_uids[item.uid] then
      report("warning", "uid '%s' 已被之前的 process 收录，本次跳过", item.uid)
    else
      deduped[#deduped + 1] = item
    end
  end
  items = deduped
  if #items == 0 then
    report("warning", "去重后无可回放题目")
    return
  end

  -- 打乱
  bem_shuffle(items, seed)

  -- 分配 seq、注入 auto uid、登记 index
  local index = {}
  for seq, item in ipairs(items) do
    item.seq = seq
    index[item.uid] = { text = item.text, buffer = item.buffer, seq = seq }
  end

  BEM.collected_groups[#BEM.collected_groups + 1] = {
    items  = items,
    filter = filter,
    spec   = spec,
  }
  for _, item in ipairs(items) do
    BEM.collected_uids[item.uid] = true
  end
  BEM.segment_index = BEM.segment_index or {}
  for uid, info in pairs(index) do
    BEM.segment_index[uid] = info
  end

  report("info", "Collected %d segments from [%s], seed %d", #items, spec, seed)
end

function BEM.flush_collected(spec)
  local groups = BEM.collected_groups or {}
  if #groups == 0 then
    report("warning", "nothing to place")
    return
  end

  spec = spec and spec:match("^%s*(.-)%s*$") or ""
  local selected = {}

  -- 汇总所有 group 的 items（保持组内已有顺序：组内已在 process 阶段洗过）
  local function gather_all()
    local all = {}
    for _, g in ipairs(groups) do
      for _, item in ipairs(g.items) do all[#all+1] = item end
    end
    return all
  end

  -- 多组时跨组二次洗牌；单组直接返回（组内已洗过，无需重复）
  local function maybe_reshuffle(all)
    if #groups <= 1 or #all <= 1 then return all end
    local seed = bem_seed("flush", #groups, spec)
    bem_shuffle(all, seed)
    report("info", "flush_collected: %d 组，跨组二次洗牌", #groups)
    return all
  end

  if spec == "" then
    -- 无参数：全部输出，多组时跨组随机
    selected = maybe_reshuffle(gather_all())

  elseif spec:match("^%d+$") then
    -- 单个纯数字：按数量抽取，多组时跨组随机
    local count = tonumber(spec)
    if not count or count <= 0 then
      report("warning", "placecollectedquestions: 数量 [%s] 非法，需为正整数", spec)
      return
    end
    local all = maybe_reshuffle(gather_all())
    if #all == 0 then
      report("warning", "没有可排版的题目")
      return
    end
    if count > #all then
      report("warning", "请求 %d 题，但只收集到 %d 题，改为输出全部", count, #all)
      count = #all
    end
    for i = 1, count do selected[i] = all[i] end
    report("info", "placecollectedquestions: 取 %d/%d 题", count, #all)

  else
    -- 原有逻辑：seq 列表 或 uid 列表（用户显式指定，不二次洗牌）
    local want = {}
    local is_seq = spec:match("^[%d,]+$") ~= nil
    if is_seq then
      for n in spec:gmatch("%d+") do want[tonumber(n)] = true end
      for _, g in ipairs(groups) do
        for _, item in ipairs(g.items) do
          if want[item.seq] then selected[#selected+1] = item end
        end
      end
    else
      for n in spec:gmatch("[^,%s]+") do want[n] = true end
      for _, g in ipairs(groups) do
        for _, item in ipairs(g.items) do
          if want[item.uid] then selected[#selected+1] = item end
        end
      end
    end
  end

  if #selected == 0 then
    report("warning", "没有匹配 [%s] 的题目", spec)
    return
  end

  -- 填回放队列：只有 auto uid 的题占位，用户手写 uid 的不占
  BEM.replay_queue = {}
  for _, item in ipairs(selected) do
    if item.auto then
      BEM.replay_queue[#BEM.replay_queue + 1] = item.uid
    end
  end

  for _, item in ipairs(selected) do
    if item.text then context(item.text) end
  end

  BEM.collected_uids   = {}
  BEM.collected_groups = {}
end

-- =====================================================================
-- 5. typegrade：渲染 partio 成绩单（默认读取上一遍编译的 partio 数据）
-- =====================================================================

-- BEM.data 只读，惰性建一次索引
local _children, _has_child

-- 自然排序比较函数：支持 1-1, 1-2, 1-10 这种带横杠的数字字符串
local function natural_less(a, b)
  a = tostring(a or "")
  b = tostring(b or "")
  local ta, tb = {}, {}
  for n in a:gmatch("%d+") do ta[#ta+1] = tonumber(n) end
  for n in b:gmatch("%d+") do tb[#tb+1] = tonumber(n) end
  for i = 1, math.max(#ta, #tb) do
    local va = ta[i] or 0
    local vb = tb[i] or 0
    if va ~= vb then
      return va < vb
    end
  end
  return a < b -- 如果纯数字部分相同，退化为字符串比较
end

local function ensure_index()
  if _children then return end
  _children, _has_child = {}, {}
  for id, rec in pairs(BEM.data) do
    if type(id) == "string" then
      local p = id:match("^(.-)%-%d+$")       -- 最后一段数字前的部分 = 父 id
      if p then
        local t = _children[p]
        if not t then t = {}; _children[p] = t end
        t[#t + 1] = rec
        _has_child[p] = true
      end
    end
  end
  for _, t in pairs(_children) do
    table.sort(t, function(a, b) return natural_less(a.order, b.order) end)
  end
end

-- 返回 parent_id 的所有叶子后代
local function get_sub_records(parent_id)
  ensure_index()
  local out = {}
  local function walk(id)
    for _, rec in ipairs(_children[id] or {}) do
      if _has_child[rec.id] then walk(rec.id)
      else out[#out + 1] = rec end
    end
  end
  walk(parent_id)
  return out
end

local function record_is_leaf(rec)
  if not rec or not rec.id then return false end
  ensure_index()
  return not _has_child[rec.id]
end

-- 收集要显示的行
local function build_grade_rows(idx_list, resetcum)
  local rows = {}
  local cum = 0
  for _, idx in ipairs(idx_list) do
    if resetcum then cum = 0 end
    local p = BEM.partio_data[idx]
    if p and p.questionlist then
      for _, item in ipairs(p.questionlist) do
        local qid = type(item) == "table" and item.id or item
        local rec = BEM.data[qid] or (type(item) == "table" and item)
        
        if rec then
          local sub_rows = {}
          local sub_total_point = 0
          
          for _, sub in ipairs(get_sub_records(qid)) do
            if record_is_leaf(sub) then
              local sub_pt = tonumber(sub.point) or 0
              sub_total_point = sub_total_point + sub_pt
              sub_rows[#sub_rows + 1] = {
                id     = sub.id,
                order  = sub.order or "",
                point  = sub_pt,
                cum    = 0,
                answer = sub.answer or "",
                level  = 1,
                env    = sub.env or "",
              }
            end
          end

          if #sub_rows > 0 then
            for _, sub in ipairs(sub_rows) do
              cum = cum + sub.point
              sub.cum = cum
            end
            rows[#rows + 1] = {
              id       = qid,
              order    = rec.order or "",
              point    = sub_total_point,
              cum      = cum,
              answer   = rec.answer or "",
              level    = 0,
              env      = rec.env or "",
              children = sub_rows,
            }
          else
            cum = cum + (tonumber(rec.point) or 0)
            rows[#rows + 1] = {
              id       = qid,
              order    = rec.order or "",
              point    = tonumber(rec.point) or 0,
              cum      = cum,
              answer   = rec.answer or "",
              level    = 0,
              env      = rec.env or "",
              children = {},
            }
          end
        end
      end
    end
  end
  return rows
end

local function apply_table_setup(o)
  context("\\setupTABLE[frame=on, align={middle,lohi}, split=yes, width=broad]")
  context("\\setupTABLE[each][each][align={middle,lohi}]")
  context("\\setupTABLE[c][1][width=4em]")
  context("\\setupTABLE[row][last][height=4ex]")
 
  if o.tablesetup ~= "" then
    context(o.tablesetup)
  end
end

-- 模式一：一题一行
local function render_grade_rows(rows, o)
  context("\\bTABLE")
  apply_table_setup(o)
  -- 表头
  if o.showheader then
    context.bTR()
    if o.showsub then
      context.bTD({ nc = 2, style = "bold"}) context(o.head_number) context.eTD()
    else
      context.bTD({ style = "bold"}) context(o.head_number) context.eTD()
    end
    context.bTD({ style = "bold"}) context(o.head_point)  context.eTD()
    if o.showscore then context.bTD({ style = "bold"}) context(o.head_score) context.eTD() end -- 新增
    if o.showcum    then context.bTD({ style = "bold"}) context(o.head_cum)    context.eTD() end
    if o.showanswer then context.bTD({ style = "bold"}) context(o.head_answer) context.eTD() end
    context.eTR()
  end

  for _, r in ipairs(rows) do
    local has_subs = o.showsub and (#r.children > 0)
    
    if not has_subs then
      -- 【无子题】
      context.bTR()
      if o.showsub then
        context.bTD({ nc = 2}) context(r.order) context.eTD()
      else
        context.bTD() context(r.order) context.eTD()
      end
      context.bTD() context(string.format("%g", r.point)) context.eTD()
      if o.showscore then context.bTD() context.eTD() end -- 新增：留空
      if o.showcum then 
        context.bTD() context(string.format("%g", r.cum)) context.eTD() 
      end
      if o.showanswer then
        context.bTD() if o.mode_showanswer then context(r.answer) end context.eTD()
      end
      context.eTR()
    else
      -- 【有子题】
      local total_rows = #r.children + 1 
      for i, sub in ipairs(r.children) do
        context.bTR()
        if i == 1 then
          context.bTD({ nr = total_rows}) context(r.order) context.eTD()
        end
        context.bTD() context(sub.order) context.eTD()
        context.bTD() context(string.format("%g", sub.point)) context.eTD()
        if o.showscore then context.bTD() context.eTD() end -- 新增：子题留空
        if o.showcum then 
          context.bTD() context(string.format("%g", sub.cum)) context.eTD() 
        end
        if o.showanswer then
          context.bTD() if o.mode_showanswer then context(sub.answer) end context.eTD()
        end
        context.eTR()
      end
      
      -- all 汇总行
      context.bTR()
      context.bTD() context(o.alllabel) context.eTD()
      context.bTD() context(string.format("%g", r.point)) context.eTD()
      if o.showscore then context.bTD() context.eTD() end -- 新增：all 行留空
      if o.showcum then 
        context.bTD() context(string.format("%g", r.cum)) context.eTD() 
      end
      if o.showanswer then
        context.bTD() if o.mode_showanswer then context(r.answer) end context.eTD()
      end
      context.eTR()
    end
  end

  -- 表尾：总分与签名（竖排模式）
  if o.showtotal or o.showreviewer or o.showchecker or o.showrecorder then
    -- 计算总列数
    local ncols = (o.showsub and 2 or 1) + 1
    if o.showscore then ncols = ncols + 1 end
    if o.showcum then ncols = ncols + 1 end
    if o.showanswer then ncols = ncols + 1 end
    
    local parts = {}
    if o.showtotal then
      local sum = 0
      for _, r in ipairs(rows) do sum = sum + (tonumber(r.point) or 0) end
      parts[#parts + 1] = "\\bold{" .. o.head_total .. "：" .. string.format("%g", sum) .. "}"
    end
    if o.showreviewer then parts[#parts+1] = o.head_reviewer .. "：\\blackrule[width=4em,height=.4pt]" end
    if o.showchecker  then parts[#parts+1] = o.head_checker .. "：\\blackrule[width=4em,height=.4pt]" end
    if o.showrecorder then parts[#parts+1] = o.head_recorder .. "：\\blackrule[width=4em,height=.4pt]" end

    -- 原生 TableFoot 包裹
    context("\\bTABLEfoot")
    context("\\bTR") -- 干干净净，不带任何硬编码样式
    context.bTD({ nc = ncols }) 
    
    -- 均分格子
    local nparts = #parts
    if nparts > 0 then
      local w = string.format("\\dimexpr(\\hsize/%d)\\relax", nparts)
      local cells = {}
      for _, p in ipairs(parts) do
        cells[#cells + 1] = "\\hbox to " .. w .. "{\\hss " .. p .. " \\hss}"
      end
      context("\\hbox to \\hsize{" .. table.concat(cells) .. "}")
    end
    
    context.eTD()
    context.eTR()
    context("\\eTABLEfoot")
  end
  context("\\eTABLE")
end

-- 模式二：一题一列
local function render_grade_cols(rows, o)
  local max_children = 0
  for _, r in ipairs(rows) do
    if o.showsub then
      max_children = math.max(max_children, #r.children)
    end
  end
  local has_subs = (max_children > 0)

  context("\\bTABLE")
  apply_table_setup(o)
  
  -- 第1行：主题号行
  context.bTR()
  if has_subs then
    context.bTD({ nr = 2, style = "bold"}) context(o.head_number) context.eTD()
  else
    context.bTD({ style = "bold"}) context(o.head_number) context.eTD()
  end
  
  for _, r in ipairs(rows) do
    if #r.children > 0 and o.showsub then
      -- 有子题：跨列（子题数 + 1个all列）
      context.bTD({ nc = #r.children + 1}) context(r.order) context.eTD()
    else
      -- 无子题：跨越上下两行
      if has_subs then
        context.bTD({ nr = 2}) context(r.order) context.eTD()
      else
        context.bTD() context(r.order) context.eTD()
      end
    end
  end
  context.eTR()

  -- 第2行：子题号行（仅当有子题且开启时输出）
  if has_subs then
    context.bTR()
    for _, r in ipairs(rows) do
      if #r.children > 0 and o.showsub then
        for _, sub in ipairs(r.children) do
          context.bTD() context(sub.order) context.eTD()
        end
        context.bTD() context(o.alllabel) context.eTD()
      end
    end
    context.eTR()
  end

  -- 第3行：分数行
  context.bTR()
  context.bTD({ style = "bold"}) context(o.head_point) context.eTD()
  for _, r in ipairs(rows) do
    if #r.children > 0 and o.showsub then
      -- 有子题：把每一个子题分数和all分数都列出来
      for _, sub in ipairs(r.children) do
        context.bTD() context(string.format("%g", sub.point)) context.eTD()
      end
      context.bTD() context(string.format("%g", r.point)) context.eTD()
    else
      context.bTD() context(string.format("%g", r.point)) context.eTD()
    end
  end
  context.eTR()

  -- 第4行：得分行
  if o.showscore then
    context.bTR()
    context.bTD({ style = "bold"}) context(o.head_score) context.eTD()
    for _, r in ipairs(rows) do
      if #r.children > 0 and o.showsub then
        for _ in ipairs(r.children) do
          context.bTD() context.eTD() -- 子题留空
        end
        context.bTD() context.eTD() -- all 留空
      else
        context.bTD() context.eTD()
      end
    end
    context.eTR()
  end

  -- 第5行：累计行
  if o.showcum then
    context.bTR()
    context.bTD({ style = "bold"}) context(o.head_cum) context.eTD()
    for _, r in ipairs(rows) do
      if #r.children > 0 and o.showsub then
        for _, sub in ipairs(r.children) do
          context.bTD() context(string.format("%g", sub.cum)) context.eTD()
        end
        context.bTD() context(string.format("%g", r.cum)) context.eTD()
      else
        context.bTD() context(string.format("%g", r.cum)) context.eTD()
      end
    end
    context.eTR()
  end

  -- 第6行：答案行
  if o.showanswer then
    context.bTR()
    context.bTD({ style = "bold"}) context(o.head_answer) context.eTD()
    for _, r in ipairs(rows) do
      if #r.children > 0 and o.showsub then
        for _, sub in ipairs(r.children) do
          context.bTD() if o.mode_showanswer then context(sub.answer) end context.eTD()
        end
        context.bTD() if o.mode_showanswer then context(r.answer) end context.eTD()
      else
        context.bTD() if o.mode_showanswer then context(r.answer) end context.eTD()
      end
    end
    context.eTR()
  end

  -- 表尾：总分与签名（横排模式）
  if o.showtotal or o.showreviewer or o.showchecker or o.showrecorder then
    -- 动态计算横排总列数
    local ncols = 1
    for _, r in ipairs(rows) do
      if #r.children > 0 and o.showsub then
        ncols = ncols + #r.children + 1
      else
        ncols = ncols + 1
      end
    end

    local parts = {}
    if o.showtotal then
      local sum = 0
      for _, r in ipairs(rows) do sum = sum + (tonumber(r.point) or 0) end
      parts[#parts + 1] = "\\bold{" .. o.head_total .. "：" .. string.format("%g", sum) .. "}"
    end
    if o.showreviewer then parts[#parts+1] = o.head_reviewer .. "：\\blackrule[width=4em,height=.4pt]" end
    if o.showchecker  then parts[#parts+1] = o.head_checker .. "：\\blackrule[width=4em,height=.4pt]" end
    if o.showrecorder then parts[#parts+1] = o.head_recorder .. "：\\blackrule[width=4em,height=.4pt]" end

    -- 原生 TableFoot 包裹
    context("\\bTABLEfoot")
    context("\\bTR")
    context.bTD({ nc = ncols }) 
    
    local nparts = #parts
    if nparts > 0 then
      local w = string.format("\\dimexpr(\\hsize/%d)\\relax", nparts)
      local cells = {}
      for _, p in ipairs(parts) do
        cells[#cells + 1] = "\\hbox to " .. w .. "{\\hss " .. p .. " \\hss}"
      end
      context("\\hbox to \\hsize{" .. table.concat(cells) .. "}")
    end
    
    context.eTD()
    context.eTR()
    context("\\eTABLEfoot")
  end
  context("\\eTABLE")
end

-- 模式三：纯文本列表
local function render_grade_list(rows, o)
  for _, r in ipairs(rows) do
    -- 1. 父题
    context("\\noindent ")
    context("\\bold{" .. r.order .. "}. ")
    if o.showcum then
      context("(" .. string.format("%g", r.point) .. " 分) ")
    end
    if o.showscore then 
      context(o.head_score .."[\\kern 2em] ") -- 新增：划线或留白
    end
    if o.showanswer then
        if o.mode_showanswer then 
          context(r.answer) 
        else
          context(o.head_answer .."[\\kern 2em] ")
        end
    end
    context("\\par\\nointerlineskip\\vskip 2pt ")
    
    -- 2. 子题
    if o.showsub and #r.children > 0 then
      for _, sub in ipairs(r.children) do
        context("\\noindent\\hskip 2em ")
        context(sub.order .. ". ")
        context("(" .. string.format("%g", sub.point) .. " 分) ")
        if o.showscore then 
          context(o.head_score .."[\\kern 2em] ") -- 新增：划线或留白
        end
        if o.mode_showanswer then 
          context(sub.answer) 
        else
          context(o.head_answer .."[\\kern 2em] ")
        end
        context("\\par\\nointerlineskip\\vskip 2pt ")
      end
    end
  end
end

-- 接收全部参数
function BEM.typegrade_render()
  local function get_param(name)
    return token.getexpansion("\\gradeparameter{" .. name .. "}")
  end

  local function get_p(name, default)
    local v = get_param(name)
    return v ~= "" and v or (default or "")
  end

  local function is_true(s)
    return s == "true" or s == "yes" or s == "1"
  end

  local mode_showanswer = (token.getexpansion("\\ifmode_showanswer 1\\else 0\\fi") == "1")

  local spec   = get_param("partios")
  local layout = get_param("layout")
  local source = get_p("source", "last")

  local b_showsub     = is_true(get_param("showsub"))
  local b_showcum     = is_true(get_param("showcum"))
  local b_showanswer  = is_true(get_param("showanswer"))
  local b_showheader  = is_true(get_param("showheader"))
  local user_resetcum = get_param("resetcum")
  local b_resetcum    = is_true(user_resetcum)

  -- 去掉可能的外层 {} 和空白
  spec = spec:match("^%s*(.-)%s*$") or spec
  if spec:sub(1, 1) == "{" and spec:sub(-1) == "}" then
    spec = spec:sub(2, -2)
  end

  local data = (source == "current") and BEM.partio_data_new or BEM.partio_data
  if next(data) == nil then
    if not _typegrade_warned[source] then
      _typegrade_warned[source] = true
      report("warning", "typegrade: 无 partio 数据（source=%s），请再编译一遍。", source)
    end
    return
  end

  -- 把用户写的 id / 数字 / uid 统一解析成 partio 主键
  local function resolve(key)
    if data[key] then return key end
    if key:match("^%d+$") and data["partio_" .. key] then
      return "partio_" .. key
    end
    for pid, p in pairs(data) do
      if type(p) == "table" and p.uid == key then return pid end
    end
  end

  local idx_list = {}
  if spec == "" then
    -- 优先读取当前正在处理的 partio
    if BEM.current_partio_idx and data[BEM.current_partio_idx] then
      idx_list = { BEM.current_partio_idx }
    else
      -- 回退逻辑：如果找不到当前的，再去取最后一个
      for pid in pairs(data) do idx_list[#idx_list + 1] = pid end
      table.sort(idx_list, function(a, b)
        return (tonumber(data[a].serial) or 0) < (tonumber(data[b].serial) or 0)
      end)
      if #idx_list > 0 then idx_list = { idx_list[#idx_list] } end
    end
  elseif spec == "all" then
    for pid in pairs(data) do idx_list[#idx_list + 1] = pid end
    table.sort(idx_list, function(a, b)
      return (tonumber(data[a].serial) or 0) < (tonumber(data[b].serial) or 0)
    end)
  else
    local missing = {}
    for s in spec:gmatch("[^,]+") do
      local t = s:match("^%s*(.-)%s*$")
      if t ~= "" then
        local id = resolve(t)
        if id then idx_list[#idx_list + 1] = id
        else missing[#missing + 1] = t end
      end
    end
    if #missing > 0 then
      report("warning", "typegrade: 找不到 partio：%s", table.concat(missing, ", "))
    end
    if #idx_list == 0 then return end
  end

  -- 智能覆盖：如果合并了多个 partio 且用户没显式要求，则强制连续累加
  if (spec == "all" or #idx_list > 1) and user_resetcum == "" then
    b_resetcum = false
  end

  local rows = build_grade_rows(idx_list, b_resetcum)
  if #rows == 0 then
    report("warning", "typegrade: 无数据可排版（源=%s，partios=%s，serial=%d）", source, spec, BEM.partio_serial)
    return
  end

  local o = {
    showsub         = b_showsub,
    showheader      = b_showheader,
    showcum         = b_showcum,
    showanswer      = b_showanswer,
    showscore       = is_true(get_p("showscore", "true")),
    showtotal       = is_true(get_param("showtotal")),
    showreviewer    = is_true(get_param("showreviewer")),
    showchecker     = is_true(get_param("showchecker")),
    showrecorder    = is_true(get_param("showrecorder")),
    mode_showanswer = mode_showanswer,
    
    answer_width    = get_p("answerwidth", "12em"),
    head_number     = get_p("numberlabel", "题号"),
    head_point      = get_p("pointlabel",  "分数"),
    head_cum        = get_p("cumlabel",    "累计"),
    head_answer     = get_p("answerlabel", "答案"),
    head_score      = get_p("scorelabel",  "得分"), 
    head_total      = get_p("totallabel", "总分"),
    head_reviewer   = get_p("reviewerlabel", "阅卷人"),
    head_checker    = get_p("checkerlabel", "复核人"),
    head_recorder   = get_p("recorderlabel", "登分人"),

    alllabel        = get_p("alllabel", "all"),
    tablesetup      = get_p("tablesetup"),
    customhandler   = get_p("customhandler"),
    maxcols         = tonumber(get_p("maxcols", "0")) or 0,
    maxrows         = tonumber(get_p("maxrows", "0")) or 0,
  }

  if layout == "custom" or o.customhandler ~= "" then
    local fn_name = o.customhandler ~= "" and o.customhandler or "render_grade_custom"
    local fn = BEM[fn_name] or userdata[fn_name]
    if fn then fn(rows, o) else report("error", "找不到自定义渲染函数 %s", fn_name) end
    return
  end

  if layout == "cols" and o.maxcols > 0 and #rows > o.maxcols then
    -- 按 maxcols 分块
    for i = 1, #rows, o.maxcols do
      local chunk = {}
      for j = i, math.min(i + o.maxcols - 1, #rows) do
        chunk[#chunk + 1] = rows[j]
      end
      render_grade_cols(chunk, o)
      if i + o.maxcols <= #rows then
        context("\\par\\blank[small]") -- 两个表格之间留出一点间距
      end
    end
  elseif layout == "cols" then
    render_grade_cols(rows, o)
  elseif layout == "list" then
    render_grade_list(rows, o)
  else
    if o.maxrows > 0 and #rows > o.maxrows then
      local ncols = math.ceil(#rows / o.maxrows)
      
      -- 开启多栏环境，balance=yes 保证两列高度尽可能一致
      context("\\startcolumns[n=" .. ncols .. ", balance=yes]")
      
      for i = 1, #rows, o.maxrows do
        context("\\startcolumn")
        local chunk = {}
        for j = i, math.min(i + o.maxrows - 1, #rows) do
          chunk[#chunk + 1] = rows[j]
        end
        render_grade_rows(chunk, o)
        context("\\stopcolumn")
      end
      
      context("\\stopcolumns")
    else
      render_grade_rows(rows, o)
    end
  end
end

BEM.load_data()
BEM.init_tree()

-- =====================================================================
-- 4. choice 
-- =====================================================================

local bem_choice_serial = 0
local ctx_convertnumber = context.convertnumber
BEM.choice_collect = { items = {} }

-- 处理逗号列表，解析为 choice 选项
local function emit_citems(str)
  if not str or str == "" then return "" end

  local function trim(s) return s:match("^%s*(.-)%s*$") or s end
  local function has_content(s) return s and s:find("%S") ~= nil end
  local function strip_braces(s)
    s = trim(s)
    if s:sub(1, 1) == "{" and s:sub(-1, -1) == "}" then
      return s:sub(2, -2)
    end
    return s
  end

  local items = {}
  local current = {}
  local brace_depth = 0

  for c in str:gmatch(".") do
    if c == "{" then
      brace_depth = brace_depth + 1
      current[#current + 1] = c
    elseif c == "}" then
      brace_depth = brace_depth - 1
      current[#current + 1] = c
    elseif c == "," and brace_depth == 0 then
      local item = table.concat(current)
      if has_content(item) then items[#items + 1] = item end
      current = {}
    else
      current[#current + 1] = c
    end
  end

  local last_item = table.concat(current)
  if has_content(last_item) then items[#items + 1] = last_item end

  local result = {}
  for i = 1, #items do
    local item = items[i]
    local stripped = strip_braces(item)
    local trimmed = trim(stripped)

    if trimmed:sub(1, 3) == "[*]" then
      local rest = trim(trimmed:sub(4))
      result[#result + 1] = "\\startcitem[*] " .. rest .. "\\stopcitem"
    else
      result[#result + 1] = "\\startcitem " .. item .. "\\stopcitem"
    end
  end
  return table.concat(result)
end

local function bem_read_macro(name)
  return tokens.getters.macro(name) or ""
end

-- 计算自动列数：宽度能放 cap 列时，n 个选项怎么排最平衡
local function compute_auto_n(n, cap)
  if cap <= 0 then return 1 end -- 一旦非常窄，会计算出0。强制单列
  if cap >= n then return n end
  local rows = math.ceil(n / cap)
  local cols = math.ceil(n / rows)
  if n <= 4 and n % cols == 1 then
    return 1
  end
  return math.max(1, math.min(n, cols))
end

function BEM.process_choice(str)
  if not str or str == "" then return end
  context(emit_citems(str))
end

function BEM.choice_add_item(toks, flag, content_string)
  BEM.choice_collect.items[#BEM.choice_collect.items + 1] = {
    content = toks,
    content_string = content_string,
    correct = flag == "*",
  }
  BEM.citem_count = BEM.citem_count + 1
end

function BEM.choice_prepare()
  if BEM.choice_data then
    report("warning", "检测到 choice 嵌套：%s。嵌套场景可能产生错误结果。",
      BEM.choice_data.category or "?")
  end
  local collected = BEM.choice_collect.items
  local n = #collected
  bem_choice_serial = bem_choice_serial + 1

  local category = bem_read_macro("bem_choice_category")

  -- 抽离 random, 避免传递给 itemgroup 
  local opts_str = bem_read_macro("bem_choice_options") or ""
  local has_random = false
  local new_opts = {}
  local layout = nil  -- "horizontal" | "vertical" | nil，最后一次生效
  
  for raw_opt in string.gmatch(opts_str, "([^,]+)") do
    local opt = raw_opt:match("^%s*(.-)%s*$")
    if opt == "random" then
      has_random = true
    elseif opt == "horizontal" or opt == "vertical" then
      layout = opt                       -- 后出现的覆盖先出现的
      table.insert(new_opts, opt)
    elseif opt ~= "" then
      table.insert(new_opts, opt)
    end
  end

  local rp = token.getexpansion("\\choiceparameter{random}")
  if rp == "yes" or rp == "true" or rp == "1" then
    has_random = true
  end

  local d = {
    serial    = bem_choice_serial,
    category  = category,
    inline    = false,
    random    = has_random,
    items     = {},
    order     = {},
    startup_n = 1, -- 仅作 itemgroup 的启动 n；finish 里重算后不再使用
  }

  for i = 1, n do
    local item = collected[i]
    item.index = i
    d.items[i] = item
  end
  BEM.choice_collect = { items = {} }

  local inline_p = token.getexpansion("\\choiceparameter{inlinechoice}")
  local inline = (inline_p == "true") or (inline_p == "yes")
  d.inline = inline

  local maxi  = tex.dimen["d_bem_maxiwidth"] or 0
  local avail = tex.dimen["d_bem_extralabelwidth"] or 0

  local cap = (avail > 0 and maxi > 0) and math.floor(maxi / avail) or 0
  local startup_n
  if inline or layout == "vertical" then
    startup_n = 1
  elseif cap <= 0 then
    report("warning", "choice: maxiwidth (%.1fpt) < avail (%.1fpt), 强制单列且可能溢出", maxi/65536, avail/65536)
    startup_n = 1
  else
    startup_n = compute_auto_n(n, cap)
  end

  d.startup_n = startup_n

  -- 只有既没显式 horizontal 也没显式 vertical 时，才自动注入 horizontal
  if startup_n > 1 and layout == nil then
    table.insert(new_opts, "horizontal")
  end

  -- 将最终选项写回给 TeX
  tokens.setters.macro("bem_choice_options", table.concat(new_opts, ","))

  BEM.choice_data = d

  -- TeX 用这个值拼 itemgroup 的 n=<startup_n>。
  tex.count["c_availablecolumns"] = startup_n
end

function BEM.choice_finish(showanswer_param)
  local d = BEM.choice_data
  if not d then
    return
  end

  local n_param          = tonumber(token.getexpansion("\\choiceparameter{n}")) or 0
  local start_param      = token.getexpansion("\\choiceparameter{start}")
  local inline_param     = token.getexpansion("\\choiceparameter{inlinechoice}")
  local conversion_param = token.getexpansion("\\choiceparameter{numberconversion}")

  local n = #d.items
  d.inline = (inline_param == "true") or (inline_param == "yes")
  if inline_param ~= "false" then
    d.inline = d.inline or d.category == "inlinechoice"
  end

  -- TeX 已经在 \startcitem 里累计好最大宽度；list width 要等 itemgroup
  -- 真正处理完条目后才是正确的，所以 next_n 放到输出循环之后再算。
  local avail = tex.dimen["d_bem_extralabelwidth"] or 0
  local maxi  = tex.dimen["d_bem_maxiwidth"] or 0

  -- startup_n 是 read-once 的输入：itemgroup 已按 n=<startup_n> 开启；
  -- 如果用户显式 n>0，\choiceparameter{n} 会给出用户值并覆盖它。
  -- final_n 是本轮真正排几列；next_n 是本轮写回的宽度容量，与 final_n 无关。
  local startup_n = d.startup_n or 1
  local final_n   = n_param > 0 and n_param or startup_n
  local next_n    = final_n

  local order = {}
  for i = 1, n do order[i] = i end

  if d.random and n > 1 then
    local joined = {}
    for i = 1, n do joined[i] = d.items[i].content_string or "" end
    local seed = bem_seed("choice", d.category or "",
                          table.concat(joined, "\0"))
    bem_shuffle(order, seed)
  end

  d.order = order

  local inline     = d.inline
  local showanswer = showanswer_param == "1"
  local start      = tonumber(start_param) or 1
  local conversion = conversion_param

  for pos, idx in ipairs(d.order) do
    local item = d.items[idx]

    if inline then
      if item.correct then
        context("\\BEMmarksymbolon")
        context("\\startitem\\bgroup")
        if showanswer then
            context("\\applychoicestyleandcolor")
        end
        tex.sprint(item.content)
        tex.sprint("\\collectanswer{")
        tex.sprint(item.content)
        tex.sprint("}")
        -- 非最后一个选项时，输出分隔符（放在 item 内部）
        if pos < #d.order then
            tex.sprint("\\choiceparameter{separator}")
        end
        context("\\egroup\\stopitem")
        context("\\BEMmarksymboloff")
      else
        context("\\startitem ")
        tex.sprint(item.content)
        -- 非最后一个选项时，输出分隔符
        if pos < #d.order then
            tex.sprint("\\choiceparameter{separator}")
        end
        context("\\stopitem")
      end
    else
      if item.correct then
        context("\\startitem\\bgroup")
        if showanswer then
          context("\\applychoicestyleandcolor")
        end
        tex.sprint(item.content)
        context("\\egroup\\stopitem")
        -- 答案编号取“最终显示位置”，不是收集顺序
        local label = start + pos - 1
        tex.sprint("\\collectanswer{")
        ctx_convertnumber(conversion, label)
        tex.sprint("}")
      else
        context("\\startitem ")
        tex.sprint(item.content)
        context("\\stopitem")
      end
    end
  end

  if not inline then
    next_n = (avail > 0 and maxi > 0)
      and compute_auto_n(n, math.floor(maxi / avail))
      or final_n
  end

  tex.count["c_availablecolumns"] = next_n

  -- inline 时 cap 无意义（强制单列），不显示
  local cap        = inline and nil or (avail > 0 and math.floor(maxi / avail) or 0)
  local n_desc     = (n_param > 0 and n_param ~= startup_n)
    and string.format("n=%d(user=%d)", final_n, n_param)
    or  string.format("n=%d", final_n)
  local cap_desc   = cap and string.format(" max=%d", cap) or ""
  local store_desc = (next_n ~= final_n)
    and string.format(" store=%d", next_n)
    or  ""

  report("info", "Choice: %s%s%s | avail=%.1fpt maxw=%.1fpt | order=[%s] opts=[%s]",
    n_desc, cap_desc, store_desc,
    avail / 65536, maxi / 65536,
    table.concat(d.order, ","),
    bem_read_macro("bem_choice_options"))

  BEM.set_extra_data("availablecolumns", tostring(tex.count["c_availablecolumns"]))

  BEM.choice_data = nil -- 清空后，choice_prepare 的嵌套判断才准确：只有“上一个 choice 的 finish 还没执行”时才真嵌套。
end

-- =====================================================================
-- 5. close 环境的选项收集
-- =====================================================================

local close_data = { items = {}, current = 0 }

function BEM.close_reset() 
  close_data.items = {}
  close_data.current = 0
end

function BEM.close_add_choice(a, b, c)
  a, b, c = a or "", b or "", c or ""

  -- 参数位置即语义：#3 非空 -> cat/opt/content；#2 非空 -> cat/content；否则 -> content
  local prefix, content
  if c ~= "" then
    prefix, content = "[" .. a .. "][" .. b .. "]", c
  elseif b ~= "" then
    prefix, content = "[" .. a .. "]", b
  else
    prefix, content = "", a
  end

  close_data.items[#close_data.items + 1] = {
    prefix = prefix, content = content,
  }
end

function BEM.close_render_current()
  close_data.current = close_data.current + 1
  local item = close_data.items[close_data.current]
  if not item then return end
  tex.sprint("\\startclosechoice" .. item.prefix .. emit_citems(item.content) .. "\\stopclosechoice")
end

-- t-order.lua
-- ORDER 命令的 Lua 实现，独立于主文件 t-exam.lua

if not thirddata then thirddata = {} end
thirddata.basicexam = thirddata.basicexam or {}
local M = thirddata.basicexam

-- 与其他收集器共用同一张表；不要在加载时清空
M.MultiAnswerCollector = M.MultiAnswerCollector or {}

M.order = M.order or {}
local O = M.order

-- ---------------------------------------------------------------
-- 1) 工具函数
-- ---------------------------------------------------------------

-- 与 bem_shuffle 用同一个 Park–Miller 算法，
-- 同一 seed 在不同模块里得到同一置换。
local function shuffle_inplace(t, seed)
  local state = math.floor(math.abs(tonumber(seed) or 123)) % 2147483647
  if state <= 0 then state = 1 end
  local function rnd()
    state = (state * 48271) % 2147483647
    return state
  end
  for i = #t, 2, -1 do
    local j = (rnd() % i) + 1
    t[i], t[j] = t[j], t[i]
  end
  return t
end

-- 逗号分割，保护 {...} 内部的逗号，去首尾空白，丢弃空段
local function split_list(s)
  local items, cur = {}, {}
  local depth = 0
  for c in tostring(s or ""):gmatch(".") do
    if c == "{" then
      depth = depth + 1
      cur[#cur + 1] = c
    elseif c == "}" then
      depth = depth - 1
      cur[#cur + 1] = c
    elseif c == "," and depth == 0 then
      local item = table.concat(cur):match("^%s*(.-)%s*$")
      if item ~= "" then items[#items + 1] = item end
      cur = {}
    else
      cur[#cur + 1] = c
    end
  end
  local tail = table.concat(cur):match("^%s*(.-)%s*$")
  if tail ~= "" then items[#items + 1] = tail end
  return items
end

local function macro(name, default)
  local v = tokens.getters.macro(name)
  if not v or v == "" then return default end
  return v
end

local function truthy(s)
  return s == "true" or s == "yes" or s == "1"
end

-- ---------------------------------------------------------------
-- 2) 渲染 + 收集
-- ---------------------------------------------------------------

-- 参数全部由 TeX 端以确定值传入：
--   seed      : 字符串
--   list      : 原始逗号列表（已用 \luaescapestring 保护）
--   numbering : 已回落到全局或用户值的字符串
--   answermode: 同上
function O.render(seed, list, numbering, answermode)
  local items = split_list(list)
  if #items == 0 then return end

  local tagged = {}
  for i, text in ipairs(items) do
    tagged[i] = { orig = i, text = text }
  end
  shuffle_inplace(tagged, seed)

  local shuffled, pos_of_orig = {}, {}
  for pos, item in ipairs(tagged) do
    shuffled[pos] = { pos = pos, orig = item.orig, text = item.text }
    pos_of_orig[item.orig] = pos

    -- 关键：不经过 string.format，item.text 作为 TeX 代码直接输出
    context("\\RENDERORDER{%d}{", pos)
    context(item.text)
    context("}")
  end

  local correct, answer = {}, {}
  for orig, text in ipairs(items) do
    local pos = pos_of_orig[orig]
    correct[orig] = { orig = orig, pos = pos, text = text }
    answer[orig]  = tostring(pos)
  end

  -- 渲染成功才入队，避免半成品进入 collector
  table.insert(M.MultiAnswerCollector, {
    shuffled   = shuffled,
    correct    = correct,
    numbering  = numbering,
    answermode = answermode,
    answer     = table.concat(answer, ","),
  })
end

-- ---------------------------------------------------------------
-- 3) 答案输出（供 \collectd_orderanswer 调用）
-- ---------------------------------------------------------------

function O.collect_answers()
  local show_number = truthy(macro("pxordershow_number", "true"))
  local separator   = macro("pxorderseparator", ", ")
  local numbering   = macro("pxordernumbering", "numbers")
  local mode        = macro("pxorderanswermode", "correct")

  for i, entry in ipairs(M.MultiAnswerCollector) do
    if i > 1 then context("\\par") end

    if type(entry) == "string" then
      context(entry)
    else
      local m = entry.answermode
      if not m or m == "" then m = mode end

      local list = (m == "shuffled") and entry.shuffled or entry.correct
      if list then
        for j, item in ipairs(list) do
          if j > 1 then context(separator) end
          if show_number then
            -- 注意：空串要回落到全局 numbering，否则空串 truthy 会截断回落
            local nb = (entry.numbering and entry.numbering ~= "")
              and entry.numbering or numbering
            context("\\convertnumber{" .. nb .. "}{" .. item.pos .. "}.")
          end
          context(item.text)
        end
      else
        context(entry.answer or "")
      end
    end
  end
end

-- 兼容旧接口名，外部若调用 thirddata.basicexam.collectd_orderanswer() 仍可用
M.collectd_orderanswer = O.collect_answers

-- =========================================================
-- 1. 层级树操作
-- =========================================================

-- \UnlimitedPushLevel
-- 作用：进入一个新层级，创建新节点并设为当前节点
-- 用法：\UnlimitedPushLevel{question}
-- 参数：env_type - 环境类型名（如 question/subquestion）
interfaces.implement {
  name      = "UnlimitedPushLevel",
  public    = true,
  arguments = { "string" },
  actions   = function(env_type)
    BEM.push_level(env_type)
  end,
}

-- \UnlimitedAddScoredAnswer
-- 作用：为当前节点设置答案和分数，并更新祖先节点统计
-- 用法：\UnlimitedAddScoredAnswer{A}{100}
-- 参数：answer - 答案内容；point - 分数（可被 tonumber 解析的字符串）
interfaces.implement {
  name      = "UnlimitedAddScoredAnswer",
  public    = true,
  arguments = { "string", "string" },
  actions   = function(answer, point)
    BEM.add_scored_answer(answer, point)
  end,
}

-- \UnlimitedPopLevel
-- 作用：退出当前层级，返回父节点（不检查环境名）
-- 用法：\UnlimitedPopLevel
interfaces.implement {
  name    = "UnlimitedPopLevel",
  public  = true,
  actions = function()
    BEM.pop_level()
  end,
}

-- \UnlimitedPopLevelChecked
-- 作用：退出当前层级，并检查环境名是否匹配（防止跨层闭合）
-- 用法：\UnlimitedPopLevelChecked{question}
-- 参数：env_type - 期望的环境类型名
interfaces.implement {
  name      = "UnlimitedPopLevelChecked",
  public    = true,
  arguments = { "string" },
  actions   = function(env_type)
    BEM.pop_level(env_type)
  end,
}

-- \UnlimitedCheckUnclosed
-- 作用：检查是否有未闭合的环境，有则报告
-- 用法：\UnlimitedCheckUnclosed
interfaces.implement {
  name    = "UnlimitedCheckUnclosed",
  public  = true,
  actions = function()
    BEM.check_unclosed()
  end,
}

-- =========================================================
-- 2. 基本信息输出
-- =========================================================

-- \UnlimitedGetDepth
-- 作用：输出当前节点深度（数字，0 表示根）
-- 用法：\UnlimitedGetDepth
interfaces.implement {
  name    = "UnlimitedGetDepth",
  public  = true,
  actions = function()
    context(BEM.get_depth())
  end,
}

-- \UnlimitedCurrentID
-- 作用：输出当前节点 ID（如 Q-1、Q-2-1）
-- 用法：\UnlimitedCurrentID
interfaces.implement {
  name    = "UnlimitedCurrentID",
  public  = true,
  actions = function()
    context(BEM.get_current_id())
  end,
}

-- \UnlimitedSaveCurrentID
-- 作用：把当前节点 ID 保存到一个控制序列中，之后可用该控制序列引用
-- 用法：\UnlimitedSaveCurrentID\MyID   之后 \MyID 即为当前节点 ID
-- 参数：cs - 目标控制序列名（csname 类型，不带反斜杠）
interfaces.implement {
  name      = "UnlimitedSaveCurrentID",
  public    = true,
  arguments = { "csname" },
  actions   = function(cs)
    tokens.setters.macro(cs, BEM.get_current_id())
  end,
}

-- =========================================================
-- 3. 按 ID 查询单个节点属性
-- =========================================================

-- \UnlimitedDisplayPoint
-- 作用：输出指定节点的分数（叶子=自身分数，非叶子=总分）
-- 用法：\UnlimitedDisplayPoint{Q-1}
-- 参数：id - 节点 ID
local function define_id_getter(name, key)
  interfaces.implement {
    name      = name,
    public    = true,
    arguments = { "string" },
    actions   = function(id)
      BEM.tex_get(id, key)
    end,
  }
end

define_id_getter("UnlimitedDisplayPoint",  "point")

-- \UnlimitedDisplayAnswer
-- 作用：输出指定节点的答案（非叶子为子树叶子答案拼接）
-- 用法：\UnlimitedDisplayAnswer{Q-1}
define_id_getter("UnlimitedDisplayAnswer", "answer")

-- \UnlimitedIsLeaf
-- 作用：输出指定节点是否为叶子节点（true/false）
-- 用法：\UnlimitedIsLeaf{Q-1}
define_id_getter("UnlimitedIsLeaf",        "is_leaf")

-- \UnlimitedTotalNumber
-- 作用：输出指定节点下题目总数
-- 用法：\UnlimitedTotalNumber{Q-1}
define_id_getter("UnlimitedTotalNumber",   "totalnumber")

-- \UnlimitedGetOrder
-- 作用：输出指定节点的 order（如 "31"、"31-1"）
-- 用法：\UnlimitedGetOrder{Q-1}
define_id_getter("UnlimitedGetOrder",      "order")

-- \UnlimitedTotalPoint
-- 作用：等价于 \UnlimitedDisplayPoint（保留原 \let 语义）
-- 用法：\UnlimitedTotalPoint{Q-1}
define_id_getter("UnlimitedTotalPoint",    "point")

-- \UnlimitedTotalAnswer
-- 作用：等价于 \UnlimitedDisplayAnswer（保留原 \let 语义）
-- 用法：\UnlimitedTotalAnswer{Q-1}
define_id_getter("UnlimitedTotalAnswer",   "answer")

-- =========================================================
-- 4. Structure 统计（指定 level + number）
-- =========================================================

local function define_structure_getter(name, key)
  interfaces.implement {
    name      = name,
    public    = true,
    arguments = { "string", "string" },
    actions   = function(level, number)
      BEM.tex_get_structure(level, number, key)
    end,
  }
end

-- \UnlimitedStructureTotalNumber
-- 作用：输出指定 level、指定编号下的题目总数
-- 用法：\UnlimitedStructureTotalNumber{1}{1}    % level=1(chapter), number=1
define_structure_getter("UnlimitedStructureTotalNumber",   "totalnumber")

-- \UnlimitedStructureTotalPoint
-- 作用：输出指定 level、指定编号下的总分
-- 用法：\UnlimitedStructureTotalPoint{1}{1}
define_structure_getter("UnlimitedStructureTotalPoint",    "totalpoint")

-- \UnlimitedStructureLeafNumber
-- 作用：输出指定 level、指定编号下「顶层叶子」数
-- 用法：\UnlimitedStructureLeafNumber{1}{1}
define_structure_getter("UnlimitedStructureLeafNumber",    "leafnumber")

-- \UnlimitedStructureAllLeafNumber
-- 作用：输出指定 level、指定编号下所有叶子节点数（实际小题数）
-- 用法：\UnlimitedStructureAllLeafNumber{1}{1}
define_structure_getter("UnlimitedStructureAllLeafNumber", "allleafnumber")

-- =========================================================
-- 5. Structure 统计（仅 level，取当前 structure）
-- =========================================================

local function define_current_structure_getter(name, key)
  interfaces.implement {
    name      = name,
    public    = true,
    arguments = { "string" },
    actions   = function(level)
      BEM.tex_get_structure(level, "", key)
    end,
  }
end

-- \UnlimitedCurrentStructureTotalNumber
-- 作用：输出当前 structure 下指定 level 的题目总数
-- 用法：\UnlimitedCurrentStructureTotalNumber{1}
define_current_structure_getter("UnlimitedCurrentStructureTotalNumber",   "totalnumber")

-- \UnlimitedCurrentStructureTotalPoint
-- 作用：输出当前 structure 下指定 level 的总分
-- 用法：\UnlimitedCurrentStructureTotalPoint{1}
define_current_structure_getter("UnlimitedCurrentStructureTotalPoint",    "totalpoint")

-- \UnlimitedCurrentStructureLeafNumber
-- 作用：输出当前 structure 下指定 level 的顶层叶子数
-- 用法：\UnlimitedCurrentStructureLeafNumber{1}
define_current_structure_getter("UnlimitedCurrentStructureLeafNumber",    "leafnumber")

-- \UnlimitedCurrentStructureAllLeafNumber
-- 作用：输出当前 structure 下指定 level 的所有叶子节点数
-- 用法：\UnlimitedCurrentStructureAllLeafNumber{1}
define_current_structure_getter("UnlimitedCurrentStructureAllLeafNumber", "allleafnumber")

-- =========================================================
-- 6. Question level 统计
-- =========================================================

-- \UnlimitedQuestionLevelNumber
-- 作用：输出指定题目下第 N 层的子题目数
-- 用法：\UnlimitedQuestionLevelNumber{Q-1}{1}
-- 参数：id - 题目 ID；level - 相对层级（1 = 直接子题目）
interfaces.implement {
  name      = "UnlimitedQuestionLevelNumber",
  public    = true,
  arguments = { "string", "string" },
  actions   = function(id, level)
    BEM.tex_get_question_level(id, "level" .. level)
  end,
}

-- \UnlimitedQuestionLeafNumber
-- 作用：输出指定题目下所有叶子节点数
-- 用法：\UnlimitedQuestionLeafNumber{Q-1}
interfaces.implement {
  name      = "UnlimitedQuestionLeafNumber",
  public    = true,
  arguments = { "string" },
  actions   = function(id)
    BEM.tex_get_question_level(id, "leafnumber")
  end,
}

-- =========================================================
-- 7. Extra data
-- =========================================================

-- \UnlimitedSetExtraData
-- 作用：为当前节点设置额外数据（元数据）
-- 用法：\UnlimitedSetExtraData{totalitemnumber}{4}
-- 参数：key - 键名；value - 值
interfaces.implement {
  name      = "UnlimitedSetExtraData",
  public    = true,
  arguments = { "string", "string" },
  actions   = function(key, value)
    BEM.set_extra_data(key, value)
  end,
}

-- \UnlimitedGetExtraData
-- 作用：从私有数据文件读取指定节点的额外数据；缺失时输出空（非字面量 nil）
-- 用法：\UnlimitedGetExtraData{Q-1}{totalitemnumber}
interfaces.implement {
  name      = "UnlimitedGetExtraData",
  public    = true,
  arguments = { "string", "string" },
  actions   = function(id, key)
    BEM.tex_get_data(id, key)
  end,
}

-- \UnlimitedGetExtraNumber
-- 作用：从私有数据文件读取额外数据并转为数字；非法或缺失时输出默认值
-- 用法：\UnlimitedGetExtraNumber{Q-1}{totalitemnumber}{0}
-- 参数：id - 节点 ID；key - 键名；default - 默认值
interfaces.implement {
  name      = "UnlimitedGetExtraNumber",
  public    = true,
  arguments = { "string", "string", "string" },
  actions   = function(id, key, default)
    BEM.tex_get_extra_number(id, key, default)
  end,
}

-- =========================================================
-- 8. 当前节点的 answer / point（组合命令）
-- =========================================================

-- \UnlimitedCurrentAnswer
-- 作用：输出当前节点的答案（等价于 \UnlimitedGetExtraData{\UnlimitedCurrentID}{answer}）
-- 用法：\UnlimitedCurrentAnswer
interfaces.implement {
  name    = "UnlimitedCurrentAnswer",
  public  = true,
  actions = function()
    BEM.tex_get_data(BEM.get_current_id(), "answer")
  end,
}

-- \UnlimitedCurrentPoint
-- 作用：输出当前节点的分数（等价于 \UnlimitedGetExtraData{\UnlimitedCurrentID}{point}）
-- 用法：\UnlimitedCurrentPoint
interfaces.implement {
  name    = "UnlimitedCurrentPoint",
  public  = true,
  actions = function()
    BEM.tex_get_data(BEM.get_current_id(), "point")
  end,
}
