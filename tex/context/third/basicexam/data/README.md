# ConTeXt 中文排序模块

本模块为 ConTeXt 提供中文排序功能，
支持三种排序方式：拼音排序、字母排序和笔画排序。

## 功能特性

### 1. zh-pinyin 拼音排序
- 按汉字拼音排序
- 同音字按拼音字母顺序排列
- 数字归类到 "number" 类别
- 西文字母归类到 "alpha" 类别

### 2. zh-alpha 字母排序
- 中西文混排，按首字母分组
- 中文按拼音首字母归类到相应字母下
- 大小写字母合并显示（如 A 和 a 都在 a 分类下）
- 数字归类到 "number" 类别

### 3. zh-stroke 笔画排序
- 按汉字笔画数分组（一画、二画、三画...）
- 同笔画数内按笔顺代码排序
- 数字归类到 "number" 类别
- 西文字母归类到 "alpha" 类别

## 文件说明

- `sort-imp-zh.lua` - 主要排序实现文件
- `pinyin.txt` - 拼音数据文件
- `sunwb_strokeorder.txt` - 笔顺数据文件
- `t-zhindex.mklx` - 模块配置文件
- `test-comprehensive.tex` - 综合测试文件

## 使用方法

### 基本用法

```tex
\usemodule[zhindex]

\starttext
\index{测试}
\index{排序}

\setupregister[index][
  n=1,
  alternative=A,
  language=zh-pinyin,  % 或 zh-alpha, zh-stroke
]

\placeindex
\stoptext
```

### 选择排序方式

```tex
% 拼音排序
\setupregister[index][language=zh-pinyin]

% 字母排序（中西文混排）
\setupregister[index][language=zh-alpha]

% 笔画排序
\setupregister[index][language=zh-stroke]
```

## 排序规则详解

### zh-pinyin 排序规则
1. 汉字按拼音字母顺序排列
2. 同音字按拼音字母顺序排列
3. 数字归类到 "number" 类别（在最后）
4. 西文字母归类到 "alpha" 类别（在最后）

### zh-alpha 排序规则
1. 按字母分组（a-z）
2. 每组内中西文混排
3. 中文按拼音字母顺序，西文按字母顺序
4. 大小写字母合并显示
5. 数字归类到 "number" 类别（在最后）

### zh-stroke 排序规则
1. 按笔画数分组（一画、二画...）
2. 同笔画数内按笔顺代码排序
3. 笔顺代码示例：二(11) → 十(12) → 七(15) → 八(34) → 九(35)
4. 数字归类到 "number" 类别（在最后）
5. 西文字母归类到 "alpha" 类别（在最后）

## 数据文件格式

### pinyin.txt 格式
```
汉字 拼音
一 yi1
二 er4
三 san1
```

### sunwb_strokeorder.txt 格式
```
汉字 笔顺代码
一 1
二 11
三 111
```

笔顺代码说明：
- 每个数字代表一个笔画类型
- 笔画数 = 笔顺代码的长度
- 示例：㐀 笔顺 21211 = 5画（竖横竖横横）

## 测试

运行综合测试：
```bash
context test-comprehensive.tex
```

测试文件包含：
- zh-pinyin 排序测试
- zh-alpha 排序测试
- zh-stroke 排序测试

## 贡献

欢迎提交问题报告和改进建议。
