# 题目管理系统

基于ConTeXt BasicExam的题目管理系统，使用SQLite数据库存储，零外部依赖。

## ✨ 特点

- ✅ **SQLite数据库** - 持久化存储，数据安全
- ✅ **零外部依赖** - 仅使用Python标准库
- ✅ **一键启动** - 简单易用
- ✅ **智能编译** - 自动检测修改，缓存PDF
- ✅ **中文支持** - 完美支持中文题目

## 🚀 快速开始

```bash
cd /Users/soanguy/ConTeXt/tex/texmf-local/tex/context/third/cls-memos/web
./start.sh
```

浏览器访问：**http://localhost:8000**

## 📁 文件结构

```
web/
├── server.py           # Python服务器
├── init_db.py          # 数据库初始化
├── start.sh            # 启动脚本
├── index.html          # 前端界面
├── questions.db        # SQLite数据库
└── cache/              # PDF缓存
```

## 🗄️ 数据库结构

### questions（题目表）
- `id` - 题目ID
- `type` - 类型（choice/writing/problem）
- `content` - 题目内容
- `point` - 分数
- `answer` - 答案
- `explanation` - 解析
- `source` - 来源
- `year` - 年份

### answers（选项表）
- `question_id` - 题目ID
- `content` - 选项内容
- `is_correct` - 是否正确
- `position` - 位置

### question_tags（标签表）
- `question_id` - 题目ID
- `tag` - 标签名称

## 🔌 API接口

### 统计
```
GET /api/stats
```

### 题目
```
GET    /api/questions          # 列表
GET    /api/questions/{id}     # 详情
POST   /api/questions          # 创建
PUT    /api/questions/{id}     # 更新
DELETE /api/questions/{id}     # 删除
```

### 编译
```
POST /api/compile              # 编译题目
GET  /cache/{filename}.pdf     # 获取PDF
```

### 标签
```
GET /api/tags                  # 所有标签
```

## 📝 使用示例

### 添加题目
1. 点击"新建题目"
2. 选择类型（选择题/简答题/计算题）
3. 填写内容和选项
4. 保存

### 编译PDF
1. 选择题目（单击选择）
2. 点击"编译选中"
3. 查看PDF预览

## 🎯 智能编译

- **首次编译** - 生成PDF并缓存
- **再次编译** - 检测修改
  - 未修改 → 使用缓存
  - 已修改 → 重新编译

## 🔧 配置

### 修改端口
编辑 `server.py`：
```python
PORT = 8000  # 修改端口
```

### 修改数据库路径
```python
DATABASE = 'questions.db'  # 修改路径
```

## 🐛 故障排除

### 端口被占用
```bash
lsof -i :8000
kill -9 <PID>
```

### 数据库问题
```bash
rm questions.db
python3 init_db.py
```

### 编译失败
- 检查ConTeXt环境
- 检查basicexam模块
- 查看编译日志

## 📊 数据库管理

```bash
# 查看数据库
sqlite3 questions.db

# 查询题目
SELECT * FROM questions;

# 导出数据
sqlite3 questions.db .dump > backup.sql

# 导入数据
sqlite3 questions.db < backup.sql
```

## 🔒 安全建议

- 不要在公网暴露服务
- 定期备份数据库
- 使用防火墙限制访问

## 📞 技术支持

检查清单：
- Python 3.6+
- ConTeXt环境
- 数据库权限
- 端口占用

---

**版本**: v1.0  
**更新**: 2026-05-19
