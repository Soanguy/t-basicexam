# t-basicexam Project

A ConTeXt Chinese typesetting toolkit featuring three core modules: exam generation, document layout, and style customization.

---

## Modules Overview

| Module | Type | Description |
|--------|------|-------------|
| **t-basicexam** | Exam Generation | Multiple choice, fill-in-the-blank, reading comprehension, essay questions, cloze tests, etc. |
| **t-memos** | Document Layout | Multi-theme, multi-style document formatting solution with zhnumber and zhindex |
| **s-poriginal** | Style Module | Custom chapter styles requiring visualcounter module |

---

## t-basicexam - Exam Generation Module

### Features

- **Multiple Choice Questions** - Support for single and multiple selections with automatic grading
- **Fill-in-the-Blank** - Flexible answer formats
- **Reading Comprehension** - Support for long text material references
- **Essay Questions** - Free response spaces
- **Cloze Tests** - Text gap-filling with answer matching
- **Answer Control** - Centralized answer management
- **Score Control** - Flexible point configuration
- **Question Header Control** - Custom question numbering and formatting

### Usage Examples

#### Full Command Syntax

```tex
\usemodule[basicexam][mode=teacher]

\startquestion[point=4,showanswer=true,answer=B]
  This is the question stem.
  \startchoice
    \startcitem Option A \stopcitem
    \startcitem[*] Option B (Correct Answer) \stopcitem
    \startcitem Option C \stopcitem
    \startcitem Option D \stopcitem
  \stopchoice
  \startanswer
    This is the explanation.
  \stopanswer
\stopquestion
```

#### Quick Command Syntax

```tex
\question[point=4,showanswer=true]{Question stem.\choice{Option A,{[*]Option B},Option C,Option D}}
```

#### Fill-in-the-Blank

```tex
\startquestion
  The capital of China is \fillin{Beijing}.
\stopquestion
```

#### Cloze Test

```tex
\startclose[showanswer=true,point=10]
In spring, the season of \closechoice[flowers,leaves,birds,rain],
we \closechoice[walk,run,jump,fly] in the park.
\stopclose
```

#### Essay Writing

```tex
\startwriting[point=20]
  Write an essay about environmental protection (at least 300 words).
  \startanswer
    Reference essay...
  \stopanswer
\stopwriting
```

---

## t-memos - Document Layout Module

Includes `zhnumber` (Chinese numerals) and `zhindex` (Chinese index) functionality.

### Features

- **Multiple Modes**: print, kindle, draft, moresize
- **Color Themes**: red, blue, yellow, green, black, cyan, orange, purple, pink, gray, white
- **Chapter Styles**: default, simple, classics, classicnovel, colorful, line, rocket, hexa, madsen, kaolike, publish, artical
- **TOC Styles**: default, simple, classics, classicnovel, colorful, line, rocket, hexa, madsen
- **Header Styles**: book, novel, colorful, hctext, fctext, foemargin, foemarginalt, hoemargin
- **Font Size System**: Complete font sizes from 42pt to 3pt
- **Multi-language Support**: Chinese Simplified (hans), Traditional (hant), Japanese, English

### zhnumber - Chinese Numeral Conversion

**Purpose**: Converts Arabic numerals to Chinese numeral expressions, supporting integers, decimals, fractions, dates, and Ganzhi (sexagenary cycle).

**Main Commands**:

| Command | Description | Example |
|---------|-------------|---------|
| `\zhnumber{num}` | Integer conversion | `\zhnumber{12345}` → 一万二千三百四十五 |
| `\zhnumber{decimal}` | Decimal conversion | `\zhnumber{3.14}` → 三点一四 |
| `\zhnumber{fraction}` | Fraction conversion | `\zhnumber{1/2}` → 二分之一 |
| `\zhdate{date}` | Date conversion | `\zhdate{2024/1/1}` → 二〇二四年一月一日 |
| `\zhtime{time}` | Time conversion | `\zhtime{14:30}` → 十四点三十分 |
| `\zhtiangan{n}` | Heavenly Stems | `\zhtiangan{1}` → 甲 |
| `\zhdizhi{n}` | Earthly Branches | `\zhdizhi{1}` → 子 |
| `\zhganzhinian{year}` | Ganzhi Year | `\zhganzhinian{2024}` → 甲辰年 |

### zhindex - Chinese Index Sorting

**Purpose**: Provides intelligent Chinese index sorting with three sorting methods.

**Sorting Methods**:
- **zh-pinyin**: Sort by Pinyin pronunciation
- **zh-alpha**: Sort by alphabetical order
- **zh-stroke**: Sort by stroke count

**Usage**:
```tex
\usemodule[memos]
\usemodule[zhindex]

\index{Peking University}
\index{Tsinghua University}

\setupregister[index][language=zh-pinyin]
\placeindex
```

---

## s-poriginal - Style Module

Provides custom chapter styles. Requires the `visualcounter` module.

### Install visualcounter Dependency

```bash
mtxrun --script install-modules --install visualcounter
```

---

## Installation

1. Download the project files
2. Place files in `tex/texmf-local/` under your ConTeXt installation
3. Run `mtxrun --generate` to refresh file index
4. Use modules in your TeX files:
   - `\usemodule[basicexam]`
   - `\usemodule[memos]`
   - `\usemodule[poriginal]`

---

## Documentation & Examples

- **[Chinese README](doc/context/third/basicexam/README_CN.md)** - Complete documentation in Chinese
- **[basicexam Manual](doc/context/third/basicexam/basicexam-manual.tex)** - Detailed usage guide
- **[memos Manual](doc/context/third/basicexam/memos-manual-en.tex)** - Document layout documentation (English)
- **[Test Files](doc/context/third/basicexam/)**:
  - **[test-exam.tex](doc/context/third/basicexam/test-exam.tex)** - Exam generation tests
  - **[test-frame.tex](doc/context/third/basicexam/test-frame.tex)** - Frame tests
  - **[test-poriginal.tex](doc/context/third/basicexam/test-poriginal.tex)** - Style module tests
  - **[test-zhnumber.tex](doc/context/third/basicexam/test-zhnumber.tex)** - Chinese numeral tests
  - **[test-zhindex.tex](doc/context/third/basicexam/test-zhindex.tex)** - Chinese index tests

---

## License

This project is licensed under the MIT License. See LICENSE file for details.
