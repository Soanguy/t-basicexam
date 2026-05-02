# t-basicexam 项目

ConTeXt 中文排版工具集，包含试卷生成、文档排版和样式定制三大核心模块。

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Soanguy/t-basicexam)

[![zread](https://img.shields.io/badge/Ask_Zread-_.svg)](https://zread.ai/Soanguy/t-basicexam)

> **English Version**: [README.md](../../README.md)

---

## 模块概览

| 模块 | 类型 | 描述 |
|------|------|------|
| **t-basicexam** | 试卷生成 | 选择题、填空题、材料题、问答题、完形填空等 |
| **t-memos** | 文档排版 | 多主题、多样式的文档排版解决方案，含 zhnumber 和 zhindex |
| **s-poriginal** | 样式模块 | 类似 PowerPoint 的演示文稿样式，需配合 visualcounter 使用 |

---

## t-basicexam - 试卷生成模块

<img style="box-shadow: 0 0 10px rgba(0, 0, 0, 0.5);" src="https://files.seeusercontent.com/2026/05/02/icF6/260502200738.png">

### 功能特性

- **选择题** - 支持单选、多选，自动判分
- **填空题** - 灵活的答案格式
- **材料题** - 支持长文本材料引用
- **问答题** - 自由作答空间
- **完形填空** - 文本挖空与答案配对
- **答案控制** - 统一管理标准答案
- **分数控制** - 灵活的分值配置
- **题头控制** - 自定义题目编号和格式

### 使用示例

#### 完整命令语法

```tex
\usemodule[basicexam][mode=teacher]

\startquestion[point=4,showanswer=true,answer=B]
  这是题目题干内容。
  \startchoice
    \startcitem 选项 A \stopcitem
    \startcitem[*] 选项 B（正确答案）\stopcitem
    \startcitem 选项 C \stopcitem
    \startcitem 选项 D \stopcitem
  \stopchoice
  \startanswer
    这是答案解析。
  \stopanswer
\stopquestion
```

#### 快捷命令语法

```tex
\question[point=4,showanswer=true]{这是题目题干。\choice{选项A,{[*]选项B},选项C,选项D}}
```

#### 填空题

```tex
\startquestion
  李白，字\fillin{太白}，号\fillin{青莲居士}，唐代著名诗人。
\stopquestion
```

#### 材料题

```tex
\startmaterial[title={参考文献},author={作者},source={来源}]
  材料内容... \indicator{标记文本}
\stopmaterial

\startquestion
  \indicator{标记文本} 相关问题？
  \choice{答案A,答案B,答案C,答案D}
\stopquestion
```

#### 完形填空

```tex
\startclose[showanswer=true,point=10]
在春天，\closechoice[花开,叶绿,鸟鸣,雨落]的季节里，
我们\closechoice[漫步,奔跑,跳跃,飞翔]在公园里。
\stopclose
```

#### 问答题

```tex
\startwriting[point=20]
  请写一篇关于环保的作文，不少于300字。
  \startanswer
    参考范文...
  \stopanswer
\stopwriting
```

#### 试卷标题

```tex
\definepapertitle[myexam]
\setuppapertitle[myexam][
    list={secret,examtitle,subject,information,notice},
    secret={绝密 ★ 启用前},
    examtitle={2024年期末考试},
    subject={语文},
    information={总分:100分，考试时间:90分钟},
    notice={注意事项...},
]
\makepapertitle[myexam]
```

#### 答案输出

```tex
% 列表格式
\typeanswer[start=1,total=10,alternative=list]{}

% 表格格式
\typeanswer[start=1,total=10,alternative=table,rows=2,columns=5]{}
```

---

## t-memos - 文档排版模块

包含 `pinyin`（拼音注音）、`bihua`（笔画显示）、`zhnumber`（中文数字）和 `zhindex`（中文索引）功能。

<img style="box-shadow: 0 0 10px rgba(0, 0, 0, 0.5);" src="https://files.seeusercontent.com/2026/05/02/6Owk/260502200601.png">
<img style="box-shadow: 0 0 10px rgba(0, 0, 0, 0.5);" src="https://files.seeusercontent.com/2026/05/02/g4fD/260502200410.png">
<img style="box-shadow: 0 0 10px rgba(0, 0, 0, 0.5);" src="https://files.seeusercontent.com/2026/05/02/el4P/260502200631.png">
<img style="box-shadow: 0 0 10px rgba(0, 0, 0, 0.5);" src="https://files.seeusercontent.com/2026/05/02/7Twl/260502200523.png">

### 功能特性

- **多种模式支持**：print、kindle、draft、moresize
- **丰富颜色主题**：red、blue、yellow、green、black、cyan、orange、purple、pink、gray、white
- **多样章节样式**：default、simple、classics、classicnovel、colorful、line、rocket、hexa、madsen、kaolike、publish、artical
- **灵活目录样式**：default、simple、classics、classicnovel、colorful、line、rocket、hexa、madsen
- **多种页眉样式**：book、novel、colorful、hctext、fctext、foemargin、foemarginalt、hoemargin
- **完整字号系统**：从初号(42pt)到小九号(3pt)
- **多语言支持**：中文简体(hans)、繁体(hant)、日文、英文

### 加载扩展功能

```tex
% 加载特定扩展
\usemodule[memos][extra=pinyin]
\usemodule[memos][extra=bihua]
\usemodule[memos][extra=zhnumber]
\usemodule[memos][extra=index]

% 或加载所有扩展
\usemodule[memos][extra=all]
```

### pinyin - 拼音注音

**作用**：为汉字自动或手动添加拼音标注，适用于教育材料、语言学习文档等场景。

**主要命令**：

| 命令 | 说明 | 示例 |
|------|------|------|
| `\startpinyinscope ... \stoppinyinscope` | 自动注音环境 | 见下方示例 |
| `\xpinyin{文本}` | 手动注音 | `\xpinyin{汉字}` → hànzì |
| `\xpinyin[拼音]{汉字}` | 指定多音字拼音 | `\xpinyin[chong2]{重}` |
| `\setuppinyin[...]` | 设置拼音参数 | 设置 vsep、hsep、ratio 等 |

**使用示例**：

```tex
\usemodule[memos][extra=pinyin]

% 自动注音
\startpinyinscope
汉语拼音自动注音测试。
\stoppinyinscope

% 手动注音
汉字：\xpinyin{手动注音测试}

% 多音字处理
\xpinyin[chong2]{重}庆是一座美丽的城市。
```

### bihua - 笔画显示

**作用**：展示汉字的笔画顺序和结构，适用于汉字教学、书法练习等场景。

**主要命令**：

| 命令 | 说明 | 示例 |
|------|------|------|
| `\bihuaload{汉字}` | 加载汉字数据 | `\bihuaload{好学习}` |
| `\bihuashow{汉字}{笔画数}` | 显示指定笔画 | `\bihuashow{好}{3}` |
| `\bihuashowall{汉字}` | 显示所有笔画 | `\bihuashowall{好}` |
| `\definebihua[样式][...]` | 定义自定义样式 | 配置颜色、边框等 |

**边框类型**：
- **outer**：只有外框
- **tian**：田字格（十字线）
- **mi**：米字格（十字+对角线）
- **x**：只有对角线
- **none**：无边框

**使用示例**：

```tex
\usemodule[memos][extra=bihua]

\bihuaload{好学习}

% 显示指定笔画
\bihuashow{好}{3}

% 带边框显示
\bihuashow[frame=tian]{好}{3}

% 显示所有笔画
\bihuashowall{好学习}
```

### zhnumber - 中文数字转换

**作用**：将阿拉伯数字转换为中文数字表达，支持整数、小数、分数、日期、天干地支等多种格式。

**主要命令**：

| 命令 | 说明 | 示例 |
|------|------|------|
| `\zhnumber{数字}` | 整数转换 | `\zhnumber{12345}` → 一万二千三百四十五 |
| `\zhnumber{小数}` | 小数转换 | `\zhnumber{3.14}` → 三点一四 |
| `\zhnumber{分数}` | 分数转换 | `\zhnumber{1/2}` → 二分之一 |
| `\zhdate{日期}` | 日期转换 | `\zhdate{2024/1/1}` → 二〇二四年一月一日 |
| `\zhtime{时间}` | 时间转换 | `\zhtime{14:30}` → 十四点三十分 |
| `\zhtoday` | 今日日期 | 当前日期的中文表达 |
| `\zhcurrtime` | 当前时间 | 当前时间的中文表达 |
| `\zhtiangan{n}` | 天干 | `\zhtiangan{1}` → 甲 |
| `\zhdizhi{n}` | 地支 | `\zhdizhi{1}` → 子 |
| `\zhganzhi{n}` | 干支 | `\zhganzhi{1}` → 甲子 |
| `\zhganzhinian{年份}` | 干支纪年 | `\zhganzhinian{2024}` → 甲辰年 |

**样式选项**：

```tex
\zhnumber[normal]{12345}    % 一万二千三百四十五（普通）
\zhnumber[cap]{12345}       % 壹万贰仟叁佰肆拾伍（大写）
\zhnumber[all]{23}          % 廿三（特殊格式）

% 设置零的显示
\setupzhnumber[zero=零]      % 使用"零"
\setupzhnumber[zero=〇]      % 使用"〇"（默认）
```

### zhindex - 中文索引排序

**作用**：提供中文索引的智能排序功能，支持拼音、字母、笔画三种排序方式。

**主要特性**：

- **zh-pinyin**：按拼音排序，同音字按拼音字母顺序排列
- **zh-alpha**：按字母顺序排序，汉字按拼音字母顺序排列
- **zh-stroke**：按笔画数排序，同笔画数按笔顺代码排列

**使用示例**：

```tex
\usemodule[memos][extra=index]

% 添加索引项
\index{北京大学}
\index{清华大学}
\index{复旦大学}
\index{上海交通大学}

% 按拼音排序输出
\setupregister[index][language=zh-pinyin]
\placeindex

% 按笔画排序输出
\setupregister[index][language=zh-stroke]
\placeindex
```

**支持的内容类型**：
- 中文词语和短语
- 英文单词和缩写
- 数字和符号
- 中西文混合内容
- 生僻字和复杂字符

### 使用示例

```tex
\usemodule[memos][
  papersize=A4,
  layout=moderate,
  mainlanguage=hans,
  fontsize=11pt,
  themecolor=blue,
  chapterstyle=simple,
  hdrstyle=book,
]

\starttext
\chapter{第一章}
\section{第一节}
这是正文内容，包含中文数字：\zhnumber{2024}年。

\index{测试索引}
\placeindex
\stoptext
```

---

## s-poriginal - 样式模块

提供类似 PowerPoint 的演示文稿样式支持，需要配合 `visualcounter` 模块使用。

### 安装 visualcounter 依赖

```bash
mtxrun --script install-modules --install visualcounter
```

或手动安装：
1. 从 GitHub 下载：[https://github.com/adityam/visualcounter](https://github.com/adityam/visualcounter)
2. 将 `t-visualcounter.mkvi` 复制到 `tex/texmf-local/context/third/`
3. 运行 `mtxrun --generate` 刷新索引

---

## 安装说明

1. 下载项目文件
2. 将文件放置在 ConTeXt 安装路径下的 `tex/texmf-local/` 目录
3. 在终端运行：`mtxrun --generate` 刷新文件索引
4. 在 TeX 文件中使用相应模块：
   - `\usemodule[basicexam]`
   - `\usemodule[memos]`
   - `\usemodule[poriginal]`

---

## 文档与示例

- **[basicexam 手册](basicexam-manual.tex)**：详细的使用指南
- **[memos 手册](memos-manual.tex)**：文档排版模块说明
- **[memos 手册（英文）](memos-manual-en.tex)**：文档排版模块说明（英文版）
- **[试卷生成测试](test-exam.tex)**：basicexam 模块测试示例
- **[框架测试](test-frame.tex)**：框架功能测试
- **[样式模块测试](test-poriginal.tex)**：s-poriginal 模块测试
- **[中文数字测试](test-zhnumber.tex)**：zhnumber 功能测试
- **[中文索引测试](test-zhindex.tex)**：zhindex 功能测试
- **[拼音注音测试](test-pinyin.tex)**：pinyin 功能测试
- **[笔画显示测试](test-bihua.tex)**：bihua 功能测试
