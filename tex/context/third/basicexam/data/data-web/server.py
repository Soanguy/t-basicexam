#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
轻量级题目管理系统服务器
使用Python标准库，无需安装任何依赖
支持SQLite数据库
"""

import http.server
import socketserver
import json
import sqlite3
import os
import hashlib
import subprocess
import shutil
from datetime import datetime
from urllib.parse import urlparse, parse_qs
import re
import threading
import logging
from contextlib import contextmanager

DATABASE = 'questions.db'
CACHE_DIR = './cache'
LOG_FILE = 'server.log'

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

os.makedirs(CACHE_DIR, exist_ok=True)

compile_locks = {}
compile_locks_lock = threading.Lock()

def get_compile_lock(question_id):
    """获取编译锁"""
    with compile_locks_lock:
        if question_id not in compile_locks:
            compile_locks[question_id] = threading.Lock()
        return compile_locks[question_id]

@contextmanager
def get_db_context():
    """数据库连接上下文管理器"""
    conn = sqlite3.connect(DATABASE)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    except Exception as e:
        logger.error(f"数据库操作异常: {str(e)}")
        conn.rollback()
        raise
    finally:
        conn.close()

def clean_cache(max_size_mb=100, max_age_days=30):
    """清理cache目录"""
    try:
        cache_size = 0
        now = datetime.now()
        cleaned_files = 0
        
        conn = sqlite3.connect(DATABASE)
        cursor = conn.cursor()
        cursor.execute('SELECT pdf_path FROM questions WHERE pdf_path IS NOT NULL')
        db_files = set(os.path.basename(row[0]) for row in cursor.fetchall())
        conn.close()
        
        for filename in os.listdir(CACHE_DIR):
            filepath = os.path.join(CACHE_DIR, filename)
            if os.path.isfile(filepath):
                file_size_mb = os.path.getsize(filepath) / (1024 * 1024)
                cache_size += file_size_mb
                
                file_time = datetime.fromtimestamp(os.path.getmtime(filepath))
                age_days = (now - file_time).days
                
                should_delete = False
                reason = ""
                
                if filename not in db_files:
                    should_delete = True
                    reason = "孤立文件"
                elif cache_size > max_size_mb:
                    should_delete = True
                    reason = f"超过大小限制({cache_size:.2f}MB > {max_size_mb}MB)"
                elif age_days > max_age_days:
                    should_delete = True
                    reason = f"文件过旧({age_days}天 > {max_age_days}天)"
                
                if should_delete:
                    try:
                        os.remove(filepath)
                        cache_size -= file_size_mb
                        cleaned_files += 1
                        logger.info(f"清理缓存文件: {filename} - {reason}")
                    except Exception as e:
                        logger.error(f"清理缓存文件失败: {filename} - {str(e)}")
        
        if cleaned_files > 0:
            logger.info(f"缓存清理完成: 清理了 {cleaned_files} 个文件，当前大小 {cache_size:.2f}MB")
        
        return cleaned_files
    except Exception as e:
        logger.error(f"缓存清理异常: {str(e)}")
        return 0

def create_sample_question(qtype, content, answer, point=1, explanation='', source='2023年高考', year=2023, tags=None, answers=None):
    """创建示例题目的辅助函数"""
    return {
        'type': qtype,
        'content': content,
        'point': point,
        'answer': answer,
        'explanation': explanation,
        'source': source,
        'year': year,
        'tags': tags or [],
        'answers': answers or []
    }

def create_choice(content, correct_idx, options, **kwargs):
    """创建选择题的辅助函数"""
    answers = [{'content': opt, 'is_correct': 1 if i == correct_idx else 0} 
               for i, opt in enumerate(options)]
    answer = chr(65 + correct_idx)
    return create_sample_question('choice', content, answer, answers=answers, **kwargs)

def create_writing(content, answer, **kwargs):
    """创建简答题的辅助函数"""
    return create_sample_question('writing', content, answer, **kwargs)

def create_question(content, answer, **kwargs):
    """创建问答题的辅助函数"""
    return create_sample_question('question', content, answer, **kwargs)

def init_database():
    """初始化数据库"""
    conn = sqlite3.connect(DATABASE)
    cursor = conn.cursor()
    
    cursor.executescript('''
        CREATE TABLE IF NOT EXISTS materials (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            title         TEXT UNIQUE,
            content       TEXT NOT NULL,
            author        TEXT,
            source        TEXT
        );

        CREATE TABLE IF NOT EXISTS questions (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            type          TEXT NOT NULL,
            content       TEXT NOT NULL,
            point         REAL DEFAULT 1,
            answer        TEXT,
            explanation   TEXT,
            material_id   INTEGER,
            source        TEXT,
            year          INTEGER,
            difficulty    INTEGER DEFAULT 1,
            content_hash  TEXT,
            pdf_path      TEXT,
            compiled_at   TEXT,
            updated_at    TEXT DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (material_id) REFERENCES materials(id)
        );

        CREATE TABLE IF NOT EXISTS answers (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            question_id   INTEGER NOT NULL,
            content       TEXT NOT NULL,
            answer        TEXT,
            explanation   TEXT,
            is_correct    INTEGER DEFAULT 0,
            position      INTEGER DEFAULT 0,
            FOREIGN KEY (question_id) REFERENCES questions(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS question_tags (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            question_id   INTEGER NOT NULL,
            tag           TEXT NOT NULL,
            FOREIGN KEY (question_id) REFERENCES questions(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS sub_questions (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            question_id   INTEGER NOT NULL,
            type          TEXT NOT NULL,
            content       TEXT NOT NULL,
            point         REAL DEFAULT 1,
            answer        TEXT,
            explanation   TEXT,
            position      INTEGER DEFAULT 0,
            FOREIGN KEY (question_id) REFERENCES questions(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS sub_answers (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            sub_question_id INTEGER NOT NULL,
            content       TEXT NOT NULL,
            is_correct    INTEGER DEFAULT 0,
            position      INTEGER DEFAULT 0,
            FOREIGN KEY (sub_question_id) REFERENCES sub_questions(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_questions_type ON questions(type);
        CREATE INDEX IF NOT EXISTS idx_questions_material ON questions(material_id);
        CREATE INDEX IF NOT EXISTS idx_answers_question ON answers(question_id);
        CREATE INDEX IF NOT EXISTS idx_answers_position ON answers(position);
        CREATE INDEX IF NOT EXISTS idx_question_tags_tag ON question_tags(tag);
        CREATE INDEX IF NOT EXISTS idx_question_tags_question ON question_tags(question_id);
        CREATE INDEX IF NOT EXISTS idx_sub_questions_question ON sub_questions(question_id);
        CREATE INDEX IF NOT EXISTS idx_sub_answers_question ON sub_answers(sub_question_id);
    ''')
    
    try:
        cursor.execute('ALTER TABLE questions ADD COLUMN content_hash TEXT')
    except sqlite3.OperationalError:
        pass
    
    try:
        cursor.execute('ALTER TABLE questions ADD COLUMN pdf_path TEXT')
    except sqlite3.OperationalError:
        pass
    
    try:
        cursor.execute('ALTER TABLE questions ADD COLUMN compiled_at TEXT')
    except sqlite3.OperationalError:
        pass
    
    try:
        cursor.execute('ALTER TABLE questions ADD COLUMN updated_at TEXT DEFAULT CURRENT_TIMESTAMP')
    except sqlite3.OperationalError:
        pass
    
    cursor.execute('SELECT COUNT(*) FROM questions')
    if cursor.fetchone()[0] > 0:
        conn.commit()
        conn.close()
        return
    
    sample_materials = [
        {
            'title': '全球气候变化',
            'content': '全球气候变化是当今世界面临的重大挑战之一。根据联合国政府间气候变化专门委员会（IPCC）的报告，全球平均气温在过去100年中上升了约0.85°C。气候变化导致极端天气事件频发，海平面上升，冰川融化等问题。',
            'source': '2023年高考',
            'sub_questions': [
                {
                    'type': 'choice',
                    'content': '根据材料，过去100年全球平均气温上升了约多少度？',
                    'point': 1,
                    'answer': 'B',
                    'explanation': '根据材料，全球平均气温在过去100年中上升了约0.85°C。',
                    'answers': [
                        {'content': '0.5°C', 'is_correct': 0},
                        {'content': '0.85°C', 'is_correct': 1},
                        {'content': '1.0°C', 'is_correct': 0},
                        {'content': '1.5°C', 'is_correct': 0}
                    ]
                },
                {
                    'type': 'choice',
                    'content': '以下哪个不是气候变化导致的后果？',
                    'point': 1,
                    'answer': 'D',
                    'explanation': '根据材料，气候变化导致极端天气事件频发、海平面上升、冰川融化等问题。',
                    'answers': [
                        {'content': '极端天气事件频发', 'is_correct': 0},
                        {'content': '海平面上升', 'is_correct': 0},
                        {'content': '冰川融化', 'is_correct': 0},
                        {'content': '地震频发', 'is_correct': 1}
                    ]
                },
                {
                    'type': 'writing',
                    'content': '请根据材料分析气候变化的主要原因及应对措施。',
                    'point': 5,
                    'answer': '主要原因：化石燃料燃烧、森林砍伐等。应对措施：发展可再生能源、植树造林、节能减排等。',
                    'explanation': '气候变化主要由人类活动导致，需要全球合作应对。'
                }
            ]
        }
    ]
    
    for mat in sample_materials:
        cursor.execute('SELECT id FROM materials WHERE title = ?', (mat['title'],))
        existing = cursor.fetchone()
        
        if existing:
            material_id = existing[0]
        else:
            cursor.execute('''
                INSERT INTO materials (title, content, source)
                VALUES (?, ?, ?)
            ''', (mat['title'], mat['content'], mat.get('source', '')))
            
            material_id = cursor.lastrowid
            
            for sub_q in mat.get('sub_questions', []):
                cursor.execute('''
                    INSERT INTO questions (type, content, point, answer, explanation, material_id, source, year)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ''', (sub_q['type'], sub_q['content'], sub_q['point'], sub_q['answer'], sub_q['explanation'], material_id, mat.get('source', ''), 2023))
                
                question_id = cursor.lastrowid
                
                for idx, ans in enumerate(sub_q.get('answers', [])):
                    cursor.execute('''
                        INSERT INTO answers (question_id, content, is_correct, position)
                        VALUES (?, ?, ?, ?)
                    ''', (question_id, ans['content'], ans['is_correct'], idx))
    
    sample_questions = [
        create_choice('以下哪个是质数？', 1, ['1', '2', '4', '6'], 
                     point=2, explanation='只有2是质数，其他都是合数。', tags=['数学', '数论']),
        create_choice('圆周率$\\pi$的近似值是多少？', 2, ['$2.718$', '$1.414$', '$3.141$', '$1.732$'], 
                     explanation='圆周率$\\pi$约等于$3.14159$。', source='2022年高考', year=2022, tags=['数学', '几何']),
        create_writing('请简述{\\bf 勾股定理}的内容及其应用。', 
                      '勾股定理：直角三角形两直角边的平方和等于斜边的平方，即$a^2 + b^2 = c^2$。应用：建筑、测量等。',
                      point=5, explanation='勾股定理是几何学中的重要定理，在建筑、测量、导航等领域有广泛应用。', tags=['数学', '几何', '定理']),
        create_question('计算：$\\int_0^\\pi \\sin(x)\\,dx$', '$2$', 
                      point=3, explanation='$\\int_0^\\pi \\sin(x)\\,dx = [-\\cos(x)]_0^\\pi = -\\cos(\\pi) - (-\\cos(0)) = 1 + 1 = 2$', 
                      source='2021年高考', year=2021, tags=['数学', '微积分', '积分']),
        create_choice('以下哪个国家{\\bf 不属于}欧洲？', 3, ['法国', '德国', '意大利', '日本'], 
                     explanation='日本位于亚洲。', tags=['地理', '世界地理']),
        create_writing('勾股定理：在直角三角形中，两直角边的平方和等于{{1}}的平方。这个定理的公式是{{2}}。', 
                      '斜边|$a^2 + b^2 = c^2$', 
                      point=2, explanation='勾股定理是直角三角形的基本定理，$a^2 + b^2 = c^2$，其中c为斜边。', 
                      source='2022年高考', year=2022, tags=['数学', '几何', '定理']),
        create_writing('牛顿第二定律：$F = {{1}}$，其中F为力，m为质量，a为加速度。力的单位是{{2}}。', 
                      'ma|牛顿', 
                      point=2, explanation='牛顿第二定律描述了力、质量和加速度之间的关系。', tags=['物理', '力学', '定律']),
        create_choice('以下哪个是{\\bf 光合作用}的产物？', 0, ['氧气$O_2$', '二氧化碳$CO_2$', '氮气$N_2$', '氢气$H_2$'], 
                     explanation='光合作用产生氧气和有机物。', source='2022年高考', year=2022, tags=['生物', '植物生理']),
        create_choice('《红楼梦》的作者是谁？', 1, ['罗贯中', '曹雪芹', '施耐庵', '吴承恩'], 
                     explanation='《红楼梦》是曹雪芹的代表作。', tags=['语文', '文学', '名著']),
        create_writing('请解释什么是{\\bf 可持续发展}，并举例说明。', 
                      '可持续发展是指既满足当代人的需求，又不损害后代人满足其需求的能力的发展。例如：可再生能源的使用、循环经济等。',
                      point=5, explanation='可持续发展是当今世界的重要发展理念，涉及经济、社会、环境三个方面。', 
                      source='2022年高考', year=2022, tags=['地理', '环境', '发展']),
        create_question('解方程：$x^2 - 5x + 6 = 0$', '$x_1 = 2, x_2 = 3$', 
                      point=3, explanation='使用因式分解：$(x-2)(x-3) = 0$，所以$x_1 = 2, x_2 = 3$', 
                      source='2021年高考', year=2021, tags=['数学', '代数', '方程']),
        create_choice('以下哪个{\\bf 不是}可再生能源？', 2, ['太阳能', '风能', '石油', '水能'], 
                     explanation='石油是不可再生能源。', source='2022年高考', year=2022, tags=['地理', '能源', '环境']),
        create_writing('化学方程式：$2H_2 + O_2 = {{1}}$（点燃条件）。这个反应的类型是{{2}}反应。', 
                      '2H_2O|化合', 
                      point=2, explanation='氢气在氧气中燃烧生成水，这是一个化合反应。', tags=['化学', '化学反应']),
        create_writing('请分析《老人与海》中{\\bf 桑地亚哥}的形象特点。', 
                      '桑地亚哥是一个坚韧不拔、永不言败的硬汉形象。他在与鲨鱼的搏斗中展现了人类的尊严和勇气。',
                      point=6, explanation='海明威通过桑地亚哥这一形象，塑造了"硬汉"的典型，体现了人类面对困境时的坚韧精神。', 
                      source='2022年高考', year=2022, tags=['语文', '文学', '外国文学'])
    ]
    
    cursor.execute('SELECT id FROM materials LIMIT 1')
    material_row = cursor.fetchone()
    if material_row:
        sample_questions.append({
            'type': 'material',
            'content': '全球气候变化',
            'point': 5,
            'answer': '',
            'explanation': '',
            'material_id': material_row[0],
            'source': '2023年高考',
            'year': 2023,
            'tags': ['地理', '环境', '气候变化'],
            'answers': []
        })
    
    for q in sample_questions:
        cursor.execute('''
            INSERT INTO questions (type, content, point, answer, explanation, material_id, source, year)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', (q['type'], q['content'], q['point'], q['answer'], q['explanation'], q.get('material_id'), q['source'], q['year']))
        
        question_id = cursor.lastrowid
        
        for tag in q.get('tags', []):
            cursor.execute('INSERT INTO question_tags (question_id, tag) VALUES (?, ?)', (question_id, tag))
        
        for idx, ans in enumerate(q.get('answers', [])):
            cursor.execute('''
                INSERT INTO answers (question_id, content, is_correct, position)
                VALUES (?, ?, ?, ?)
            ''', (question_id, ans['content'], ans['is_correct'], idx))
    
    conn.commit()
    conn.close()

def get_db():
    """获取数据库连接"""
    conn = sqlite3.connect(DATABASE)
    conn.row_factory = sqlite3.Row
    return conn

def compute_question_hash(question_id):
    """计算单个题目的哈希值"""
    conn = get_db()
    cursor = conn.cursor()
    
    hash_content = ""
    
    cursor.execute('SELECT * FROM questions WHERE id = ?', (question_id,))
    question = cursor.fetchone()
    if question:
        hash_content += json.dumps(dict(question), sort_keys=True)
        
        cursor.execute('SELECT * FROM answers WHERE question_id = ? ORDER BY position', (question_id,))
        answers = cursor.fetchall()
        for ans in answers:
            hash_content += json.dumps(dict(ans), sort_keys=True)
        
        cursor.execute('SELECT tag FROM question_tags WHERE question_id = ?', (question_id,))
        tags = cursor.fetchall()
        for tag in tags:
            hash_content += tag['tag']
    
    conn.close()
    return hashlib.md5(hash_content.encode()).hexdigest()

def generate_question_tex(question_dict, cursor, show_answer=True, show_more=True):
    """生成单个题目的tex内容"""
    qtype = question_dict['type']
    qcontent = question_dict['content'] or ''
    point = question_dict['point'] or 1
    answer = question_dict['answer'] or ''
    explanation = question_dict['explanation'] or ''
    source = question_dict.get('source') or ''
    year = question_dict.get('year')
    difficulty = question_dict.get('difficulty')
    content = ''
    
    moreinfo_parts = []
    if difficulty:
        moreinfo_parts.append(f'难度: {difficulty}')
    if year:
        moreinfo_parts.append(f'年份: {year}')
    if source:
        moreinfo_parts.append(f'来源: {source}')
    moreinfo = ','.join(moreinfo_parts) if moreinfo_parts else ''
    
    if qtype == 'choice':
        cursor.execute('SELECT * FROM answers WHERE question_id = ? ORDER BY position', (question_dict['id'],))
        choices = cursor.fetchall()
        
        has_fillin = False
        if answer and show_answer:
            answers = answer.split('|')
            for idx, ans in enumerate(answers, 1):
                if f'{{{{{idx}}}}}' in qcontent:
                    has_fillin = True
                    qcontent = qcontent.replace(f'{{{{{idx}}}}}', f'\\fillin{{{ans}}}', 1)
        
        if show_answer:
            if has_fillin:
                if moreinfo and show_more:
                    content += f"\\startquestion[point={point}, showanswer=yes, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startquestion[point={point}, showanswer=yes]\n"
            else:
                if moreinfo and show_more:
                    content += f"\\startquestion[point={point}, answer={{{answer}}}, showanswer=yes, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startquestion[point={point}, answer={{{answer}}}, showanswer=yes]\n"
        else:
            if moreinfo and show_more:
                content += f"\\startquestion[point={point}, showmore=yes, moreinfo={{{moreinfo}}}]\n"
            else:
                content += f"\\startquestion[point={point}]\n"
        
        content += f"{qcontent} "
        content += f"\\startchoice\n"
        
        for idx, choice in enumerate(choices):
            choice_dict = dict(choice)
            choice_content = choice_dict.get('content', '') or ''
            is_correct = choice_dict.get('is_correct', 0)
            if is_correct and show_answer:
                content += f"  \\startcitem[*] {choice_content} \\stopcitem\n"
            else:
                content += f"  \\startcitem {choice_content} \\stopcitem\n"
        
        content += "\\stopchoice\n"
        if show_more and explanation:
            content += "\\startanswer[showanswer=no,showsolution=yes,inbetween=]\n"
            content += f"解析：{explanation}\n"
            content += "\\stopanswer\n"
        content += "\\stopquestion\n\n"
    
    elif qtype == 'writing':
        if show_answer:
            if moreinfo and show_more:
                content += f"\\startwriting[point={point}, showanswer=yes, showmore=yes, moreinfo={{{moreinfo}}}]\n"
            else:
                content += f"\\startwriting[point={point}, showanswer=yes]\n"
        else:
            if moreinfo and show_more:
                content += f"\\startwriting[point={point}, showmore=yes, moreinfo={{{moreinfo}}}]\n"
            else:
                content += f"\\startwriting[point={point}]\n"
        
        if answer and show_answer:
            answers = answer.split('|')
            for idx, ans in enumerate(answers, 1):
                qcontent = qcontent.replace(f'{{{{{idx}}}}}', f'\\fillin{{{ans}}}', 1)
        
        content += f"{qcontent}\n"
        if show_more and explanation:
            content += "\\startanswer[showanswer=no,showsolution=yes,inbetween=]\n"
            content += f"{explanation}\n"
            content += "\\stopanswer\n"
        content += "\\stopwriting\n\n"
    
    elif qtype == 'multi_question':
        cursor.execute('SELECT * FROM sub_questions WHERE question_id = ? ORDER BY position', (question_dict['id'],))
        sub_questions = cursor.fetchall()
        
        if sub_questions:
            if show_answer:
                if moreinfo and show_more:
                    content += f"\\startquestion[point={point}, showanswer=yes, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startquestion[point={point}, showanswer=yes]\n"
            else:
                if moreinfo and show_more:
                    content += f"\\startquestion[point={point}, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startquestion[point={point}]\n"
            
            if qcontent:
                content += f"{qcontent}\n"
            
            content += "\\startproblem\n"
            
            for sub_q in sub_questions:
                sub_content = sub_q['content'] or ''
                sub_answer = sub_q['answer'] or ''
                sub_explanation = sub_q['explanation'] or ''
                
                has_fillin = False
                if sub_answer and show_answer:
                    answers = sub_answer.split('|')
                    for idx, ans in enumerate(answers, 1):
                        if f'{{{{{idx}}}}}' in sub_content:
                            has_fillin = True
                            sub_content = sub_content.replace(f'{{{{{idx}}}}}', f'\\fillin{{{ans}}}', 1)
                
                content += f"  \\startpitem {sub_content}"
                if show_answer and sub_answer and not has_fillin:
                    content += f" （{sub_answer}）"
                content += " \\stoppitem\n"
            
            content += "\\stopproblem\n"
            
            if show_more:
                has_answer_or_explanation = any(sq['answer'] or sq['explanation'] for sq in sub_questions)
                if has_answer_or_explanation:
                    content += "\\startanswer[showanswer=no,showsolution=yes,inbetween=]\n"
                    for idx, sub_q in enumerate(sub_questions, 1):
                        sub_answer = sub_q['answer'] or ''
                        sub_explanation = sub_q['explanation'] or ''
                        if sub_answer or sub_explanation:
                            content += f"（{idx}）"
                            if sub_answer:
                                content += f"{sub_answer}"
                            if sub_explanation:
                                content += f"；{sub_explanation}"
                            content += "\\par\n"
                    content += "\\stopanswer\n"
            
            content += "\\stopquestion\n\n"
        else:
            if show_answer:
                if moreinfo and show_more:
                    content += f"\\startquestion[point={point}, showanswer=yes, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startquestion[point={point}, showanswer=yes]\n"
            else:
                if moreinfo and show_more:
                    content += f"\\startquestion[point={point}, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startquestion[point={point}]\n"
            
            if answer and show_answer:
                answers = answer.split('|')
                for idx, ans in enumerate(answers, 1):
                    qcontent = qcontent.replace(f'{{{{{idx}}}}}', f'\\fillin{{{ans}}}', 1)
            
            content += f"{qcontent}\n"
            if show_more and explanation:
                content += "\\startanswer[showanswer=no,showsolution=yes,inbetween=]\n"
                content += f"{explanation}\n"
                content += "\\stopanswer\n"
            content += "\\stopquestion\n\n"
    
    elif qtype == 'multi_writing':
        cursor.execute('SELECT * FROM sub_questions WHERE question_id = ? ORDER BY position', (question_dict['id'],))
        sub_questions = cursor.fetchall()
        
        if sub_questions:
            if show_answer:
                if moreinfo and show_more:
                    content += f"\\startwriting[point={point}, showanswer=yes, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startwriting[point={point}, showanswer=yes]\n"
            else:
                if moreinfo and show_more:
                    content += f"\\startwriting[point={point}, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startwriting[point={point}]\n"
            
            if qcontent:
                content += f"{qcontent}\n"
            
            content += "\\startsubwriting\n"
            
            for sub_q in sub_questions:
                sub_content = sub_q['content'] or ''
                sub_answer = sub_q['answer'] or ''
                sub_explanation = sub_q['explanation'] or ''
                sub_point = sub_q['point'] or 1
                
                has_fillin = False
                if sub_answer and show_answer:
                    answers = sub_answer.split('|')
                    for idx, ans in enumerate(answers, 1):
                        if f'{{{{{idx}}}}}' in sub_content:
                            has_fillin = True
                            sub_content = sub_content.replace(f'{{{{{idx}}}}}', f'\\fillin{{{ans}}}', 1)
                
                content += f"  \\startswitem[{sub_point}] {sub_content}"
                if show_answer and sub_answer and not has_fillin:
                    content += f" （{sub_answer}）"
                content += " \\stopswitem\n"
            
            content += "\\stopsubwriting\n"
            
            if show_more:
                has_answer_or_explanation = any(sq['answer'] or sq['explanation'] for sq in sub_questions)
                if has_answer_or_explanation:
                    content += "\\startanswer[showanswer=no,showsolution=yes,inbetween=]\n"
                    for idx, sub_q in enumerate(sub_questions, 1):
                        sub_answer = sub_q['answer'] or ''
                        sub_explanation = sub_q['explanation'] or ''
                        if sub_answer or sub_explanation:
                            content += f"（{idx}）"
                            if sub_answer:
                                content += f"{sub_answer}"
                            if sub_explanation:
                                content += f"；{sub_explanation}"
                            content += "\\par\n"
                    content += "\\stopanswer\n"
            
            content += "\\stopwriting\n\n"
        else:
            if show_answer:
                if moreinfo and show_more:
                    content += f"\\startwriting[point={point}, showanswer=yes, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startwriting[point={point}, showanswer=yes]\n"
            else:
                if moreinfo and show_more:
                    content += f"\\startwriting[point={point}, showmore=yes, moreinfo={{{moreinfo}}}]\n"
                else:
                    content += f"\\startwriting[point={point}]\n"
            
            if answer and show_answer:
                answers = answer.split('|')
                for idx, ans in enumerate(answers, 1):
                    qcontent = qcontent.replace(f'{{{{{idx}}}}}', f'\\fillin{{{ans}}}', 1)
            
            content += f"{qcontent}\n"
            if show_more and explanation:
                content += "\\startanswer[showanswer=no,showsolution=yes,inbetween=]\n"
                content += f"{explanation}\n"
                content += "\\stopanswer\n"
            content += "\\stopwriting\n\n"
    
    elif qtype == 'material':
        cursor.execute('SELECT * FROM materials WHERE id = ?', (question_dict['material_id'],))
        material = cursor.fetchone()
        
        if material:
            material_content = material['content'] or ''
            material_title = material['title'] or qcontent
            
            content += f"\\startmaterial[title={{{material_title}}}]\n"
            content += f"{material_content}\n"
            
            cursor.execute('SELECT * FROM questions WHERE material_id = ? AND id != ? ORDER BY id', (question_dict['material_id'], question_dict['id']))
            sub_questions = cursor.fetchall()
            
            for sub_q in sub_questions:
                sub_q_dict = dict(sub_q)
                sub_q_dict['id'] = sub_q['id']
                content += generate_question_tex(sub_q_dict, cursor, show_answer, show_more)
            
            content += "\\stopmaterial\n\n"
        else:
            content += f"\\startmaterial[title={{{qcontent}}}]\n"
            content += "\\stopmaterial\n\n"
    
    else:
        if show_answer:
            if moreinfo and show_more:
                content += f"\\startquestion[point={point}, showanswer=yes, showmore=yes, moreinfo={{{moreinfo}}}]\n"
            else:
                content += f"\\startquestion[point={point}, showanswer=yes]\n"
        else:
            if moreinfo and show_more:
                content += f"\\startquestion[point={point}, showmore=yes, moreinfo={{{moreinfo}}}]\n"
            else:
                content += f"\\startquestion[point={point}]\n"
        
        if answer and show_answer:
            answers = answer.split('|')
            for idx, ans in enumerate(answers, 1):
                qcontent = qcontent.replace(f'{{{{{idx}}}}}', f'\\fillin{{{ans}}}', 1)
        
        content += f"{qcontent}\n"
        if show_more and explanation:
            content += "\\startanswer[showanswer=no,showsolution=yes,inbetween=]\n"
            content += f"{explanation}\n"
            content += "\\stopanswer\n"
        content += "\\stopquestion\n\n"
    
    return content

def compile_single_question(question_id, force=False, module_params=None):
    """编译单个题目"""
    lock = get_compile_lock(question_id)
    
    if lock.locked():
        logger.warning(f"题目 {question_id} 正在编译中，跳过")
        return {'success': False, 'error': '题目正在编译中'}
    
    with lock:
        logger.info(f"开始编译题目 {question_id}")
        
        context_file = None
        
        try:
            conn = get_db()
            cursor = conn.cursor()
            
            cursor.execute('SELECT * FROM questions WHERE id = ?', (question_id,))
            question = cursor.fetchone()
            
            if not question:
                conn.close()
                logger.error(f"题目 {question_id} 不存在")
                return {'success': False, 'error': '题目不存在'}
            
            old_pdf_path = question['pdf_path']
            compiled_at = question['compiled_at']
            updated_at = question['updated_at']
            
            if not force and old_pdf_path and os.path.exists(old_pdf_path):
                if compiled_at and updated_at:
                    try:
                        compiled_time = datetime.fromisoformat(compiled_at.replace('Z', '+00:00').replace('+00:00', ''))
                        updated_time = datetime.fromisoformat(updated_at.replace('Z', '+00:00').replace('+00:00', ''))
                        
                        if updated_time <= compiled_time:
                            logger.info(f"题目 {question_id} 未修改，跳过编译")
                            conn.close()
                            return {'success': True, 'pdf_path': old_pdf_path, 'skipped': True}
                    except Exception as e:
                        logger.warning(f"时间比较失败: {e}")
            
            question_dict = dict(question)
            question_dict['id'] = question_id

            if module_params:
                validated = APIHandler._validate_module_params(module_params)
                module_str = APIHandler._build_module_str(validated)
            else:
                module_str = 'mainlanguage=hans,bodyfont=adobehans'
            content = f"\\usemodule[memos][{module_str}]\\usemodule[basicexam]\\startTEXpage[offset=2em]"
            content += generate_question_tex(question_dict, cursor, show_answer=True, show_more=True)
            content += "\\stopTEXpage"
            
            conn.close()
            
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            context_file = f'question_{question_id}_{timestamp}.tex'
            pdf_file = f'question_{question_id}_{timestamp}.pdf'
            
            with open(context_file, 'w', encoding='utf-8') as f:
                f.write(content)
            
            result = subprocess.run(
                ['context', '--purge', context_file],
                capture_output=True,
                text=True,
                timeout=60
            )
            
            if result.returncode == 0 and os.path.exists(pdf_file):
                if old_pdf_path and os.path.exists(old_pdf_path):
                    try:
                        os.remove(old_pdf_path)
                        logger.info(f"已删除旧PDF: {old_pdf_path}")
                    except Exception as e:
                        logger.error(f"删除旧PDF失败: {e}")
                
                cache_pdf_path = os.path.join(CACHE_DIR, pdf_file)
                shutil.move(pdf_file, cache_pdf_path)
                
                conn = get_db()
                cursor = conn.cursor()
                cursor.execute('UPDATE questions SET pdf_path = ?, compiled_at = CURRENT_TIMESTAMP WHERE id = ?', 
                             (cache_pdf_path, question_id))
                conn.commit()
                conn.close()
                
                temp_extensions = ['.tex', '.tuc', '.log', '.aux', '.out', '.toc']
                for ext in temp_extensions:
                    temp_file = context_file.replace('.tex', ext)
                    if os.path.exists(temp_file):
                        try:
                            os.remove(temp_file)
                        except Exception as e:
                            logger.error(f"清理临时文件失败: {temp_file}, {e}")
                
                logger.info(f"题目 {question_id} 编译成功")
                return {'success': True, 'pdf_path': cache_pdf_path}
            else:
                error_msg = result.stderr if result.stderr else f"编译失败，返回码: {result.returncode}"
                logger.error(f"题目 {question_id} 编译失败: {error_msg}")
                
                temp_extensions = ['.tex', '.tuc', '.log', '.aux', '.out', '.toc']
                for ext in temp_extensions:
                    temp_file = context_file.replace('.tex', ext)
                    if os.path.exists(temp_file):
                        try:
                            os.remove(temp_file)
                        except Exception as e:
                            logger.error(f"清理临时文件失败: {temp_file}, {e}")
                
                return {'success': False, 'error': error_msg}
                
        except subprocess.TimeoutExpired:
            logger.error(f"题目 {question_id} 编译超时")
            
            if context_file:
                temp_extensions = ['.tex', '.tuc', '.log', '.aux', '.out', '.toc']
                for ext in temp_extensions:
                    temp_file = context_file.replace('.tex', ext)
                    if os.path.exists(temp_file):
                        try:
                            os.remove(temp_file)
                        except Exception as e:
                            logger.error(f"清理临时文件失败: {temp_file}, {e}")
            
            return {'success': False, 'error': '编译超时（60秒）'}
        except Exception as e:
            logger.error(f"题目 {question_id} 编译异常: {str(e)}")
            
            if context_file:
                temp_extensions = ['.tex', '.tuc', '.log', '.aux', '.out', '.toc']
                for ext in temp_extensions:
                    temp_file = context_file.replace('.tex', ext)
                    if os.path.exists(temp_file):
                        try:
                            os.remove(temp_file)
                        except Exception as e2:
                            logger.error(f"清理临时文件失败: {temp_file}, {e2}")
            
            return {'success': False, 'error': str(e)}

class APIHandler(http.server.SimpleHTTPRequestHandler):
    """API请求处理器"""
    
    def do_GET(self):
        """处理GET请求"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        query = parse_qs(parsed_path.query)
        
        if path == '/api/stats':
            self.handle_stats()
        elif path == '/api/questions':
            self.handle_get_questions(query)
        elif path.startswith('/api/questions/'):
            question_id = int(path.split('/')[-1])
            self.handle_get_question(question_id)
        elif path == '/api/tags':
            self.handle_get_tags()
        elif path.startswith('/cache/'):
            self.handle_get_pdf(path[7:])
        else:
            super().do_GET()
    
    def do_POST(self):
        """处理POST请求"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        if path == '/api/questions':
            self.handle_create_question()
        elif path == '/api/compile':
            self.handle_compile()
        elif path == '/api/export':
            self.handle_export()
        elif path == '/api/export/pdf':
            self.handle_export_pdf()
        elif path.startswith('/api/compile/'):
            question_id = int(path.split('/')[-1])
            self.handle_compile_question(question_id)
        else:
            self.send_error(404, "Not Found")
    
    def do_PUT(self):
        """处理PUT请求"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        if path.startswith('/api/questions/'):
            question_id = int(path.split('/')[-1])
            self.handle_update_question(question_id)
        else:
            self.send_error(404, "Not Found")
    
    def do_DELETE(self):
        """处理DELETE请求"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        if path.startswith('/api/questions/'):
            question_id = int(path.split('/')[-1])
            self.handle_delete_question(question_id)
        else:
            self.send_error(404, "Not Found")
    
    def handle_stats(self):
        """获取统计信息"""
        conn = get_db()
        cursor = conn.cursor()
        
        cursor.execute('SELECT COUNT(*) as count FROM questions')
        total_questions = cursor.fetchone()['count']
        
        cursor.execute('SELECT type, COUNT(*) as count FROM questions GROUP BY type')
        type_stats = {row['type']: row['count'] for row in cursor.fetchall()}
        
        cursor.execute('SELECT COUNT(DISTINCT source) as count FROM questions WHERE source IS NOT NULL')
        total_sources = cursor.fetchone()['count']
        
        cursor.execute('SELECT COUNT(*) as count FROM questions WHERE pdf_path IS NOT NULL')
        compiled_count = cursor.fetchone()['count']
        
        conn.close()
        
        self.send_json_response({
            'total_questions': total_questions,
            'type_stats': type_stats,
            'total_sources': total_sources,
            'compiled_count': compiled_count
        })
    
    def handle_get_questions(self, query):
        """获取题目列表"""
        conn = get_db()
        cursor = conn.cursor()
        
        sql = 'SELECT * FROM questions WHERE 1=1'
        params = []
        
        if query.get('type'):
            sql += ' AND type = ?'
            params.append(query['type'][0])
        
        if query.get('source'):
            sql += ' AND source LIKE ?'
            params.append(f"%{query['source'][0]}%")
        
        if query.get('year'):
            sql += ' AND year = ?'
            params.append(query['year'][0])
        
        if query.get('tag'):
            sql += ' AND id IN (SELECT question_id FROM question_tags WHERE tag = ?)'
            params.append(query['tag'][0])
        
        sql += ' ORDER BY id DESC'
        
        cursor.execute(sql, params)
        questions = cursor.fetchall()
        
        result = []
        for q in questions:
            question_dict = dict(q)
            
            cursor.execute('SELECT tag FROM question_tags WHERE question_id = ?', (q['id'],))
            tags = [row['tag'] for row in cursor.fetchall()]
            question_dict['tags'] = tags
            
            if question_dict.get('type') == 'choice':
                cursor.execute('SELECT * FROM answers WHERE question_id = ? ORDER BY position', (q['id'],))
                answers = [dict(row) for row in cursor.fetchall()]
                question_dict['answers'] = answers
            
            if question_dict.get('pdf_path'):
                question_dict['pdf_url'] = f'/cache/{os.path.basename(question_dict["pdf_path"])}'
            
            result.append(question_dict)
        
        conn.close()
        self.send_json_response(result)
    
    def handle_get_question(self, question_id):
        """获取单个题目详情"""
        conn = get_db()
        cursor = conn.cursor()
        
        cursor.execute('SELECT * FROM questions WHERE id = ?', (question_id,))
        question = cursor.fetchone()
        
        if not question:
            conn.close()
            self.send_error(404, "Question not found")
            return
        
        question_dict = dict(question)
        
        cursor.execute('SELECT * FROM answers WHERE question_id = ? ORDER BY position', (question_id,))
        answers = [dict(row) for row in cursor.fetchall()]
        question_dict['answers'] = answers
        
        cursor.execute('SELECT tag FROM question_tags WHERE question_id = ?', (question_id,))
        tags = [row['tag'] for row in cursor.fetchall()]
        question_dict['tags'] = tags
        
        if question_dict.get('type') == 'material':
            cursor.execute('SELECT * FROM sub_questions WHERE question_id = ? ORDER BY position', (question_id,))
            sub_questions = []
            for sub_q in cursor.fetchall():
                sub_q_dict = dict(sub_q)
                cursor.execute('SELECT * FROM sub_answers WHERE sub_question_id = ? ORDER BY position', (sub_q['id'],))
                sub_answers = [dict(row) for row in cursor.fetchall()]
                sub_q_dict['answers'] = sub_answers
                sub_questions.append(sub_q_dict)
            question_dict['sub_questions'] = sub_questions
        
        if question_dict.get('pdf_path'):
            question_dict['pdf_url'] = f'/cache/{os.path.basename(question_dict["pdf_path"])}'
        
        conn.close()
        self.send_json_response(question_dict)
    
    def handle_get_tags(self):
        """获取所有标签"""
        conn = get_db()
        cursor = conn.cursor()
        
        cursor.execute('SELECT DISTINCT tag FROM question_tags ORDER BY tag')
        tags = [row['tag'] for row in cursor.fetchall()]
        
        conn.close()
        self.send_json_response(tags)
    
    def handle_create_question(self):
        """创建新题目"""
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        data = json.loads(post_data.decode('utf-8'))
        
        conn = get_db()
        cursor = conn.cursor()
        
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        
        cursor.execute('''
            INSERT INTO questions (type, content, point, answer, explanation, material_id, source, year, difficulty, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (
            data.get('type', 'problem'),
            data.get('content', ''),
            data.get('point', 1),
            data.get('answer', ''),
            data.get('explanation', ''),
            data.get('material_id'),
            data.get('source', ''),
            data.get('year'),
            data.get('difficulty', 1),
            now
        ))
        
        question_id = cursor.lastrowid
        
        if 'tags' in data:
            for tag in data['tags']:
                cursor.execute('INSERT INTO question_tags (question_id, tag) VALUES (?, ?)', (question_id, tag))
        
        if 'answers' in data:
            for idx, answer in enumerate(data['answers']):
                cursor.execute('''
                    INSERT INTO answers (question_id, content, answer, explanation, is_correct, position)
                    VALUES (?, ?, ?, ?, ?, ?)
                ''', (
                    question_id,
                    answer.get('content', ''),
                    answer.get('answer', ''),
                    answer.get('explanation', ''),
                    answer.get('is_correct', 0),
                    idx
                ))
        
        if data.get('type') in ['material', 'multi_question', 'multi_writing'] and 'sub_questions' in data:
            for idx, sub_q in enumerate(data['sub_questions']):
                cursor.execute('''
                    INSERT INTO sub_questions (question_id, type, content, point, answer, explanation, position)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ''', (
                    question_id,
                    sub_q.get('type', 'problem'),
                    sub_q.get('content', ''),
                    sub_q.get('point', 1),
                    sub_q.get('answer', ''),
                    sub_q.get('explanation', ''),
                    idx
                ))
                
                sub_question_id = cursor.lastrowid
                
                if 'answers' in sub_q:
                    for a_idx, answer in enumerate(sub_q['answers']):
                        cursor.execute('''
                            INSERT INTO sub_answers (sub_question_id, content, is_correct, position)
                            VALUES (?, ?, ?, ?)
                        ''', (
                            sub_question_id,
                            answer.get('content', ''),
                            answer.get('is_correct', 0),
                            a_idx
                        ))
        
        conn.commit()
        
        content_hash = compute_question_hash(question_id)
        cursor.execute('UPDATE questions SET content_hash = ? WHERE id = ?', (content_hash, question_id))
        conn.commit()
        conn.close()
        
        self.send_json_response({
            'id': question_id, 
            'message': '题目创建成功'
        }, 201)
    
    def handle_update_question(self, question_id):
        """更新题目"""
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        data = json.loads(post_data.decode('utf-8'))
        
        conn = get_db()
        cursor = conn.cursor()
        
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        
        cursor.execute('''
            UPDATE questions 
            SET type = ?, content = ?, point = ?, answer = ?, explanation = ?, 
                source = ?, year = ?, difficulty = ?, updated_at = ?
            WHERE id = ?
        ''', (
            data.get('type'),
            data.get('content'),
            data.get('point'),
            data.get('answer'),
            data.get('explanation'),
            data.get('source'),
            data.get('year'),
            data.get('difficulty'),
            now,
            question_id
        ))
        
        if 'tags' in data:
            cursor.execute('DELETE FROM question_tags WHERE question_id = ?', (question_id,))
            for tag in data['tags']:
                cursor.execute('INSERT INTO question_tags (question_id, tag) VALUES (?, ?)', (question_id, tag))
        
        if 'answers' in data:
            cursor.execute('DELETE FROM answers WHERE question_id = ?', (question_id,))
            for idx, answer in enumerate(data['answers']):
                cursor.execute('''
                    INSERT INTO answers (question_id, content, answer, explanation, is_correct, position)
                    VALUES (?, ?, ?, ?, ?, ?)
                ''', (
                    question_id,
                    answer.get('content', ''),
                    answer.get('answer', ''),
                    answer.get('explanation', ''),
                    answer.get('is_correct', 0),
                    idx
                ))
        
        if data.get('type') in ['material', 'multi_question', 'multi_writing'] and 'sub_questions' in data:
            cursor.execute('DELETE FROM sub_answers WHERE sub_question_id IN (SELECT id FROM sub_questions WHERE question_id = ?)', (question_id,))
            cursor.execute('DELETE FROM sub_questions WHERE question_id = ?', (question_id,))
            
            for idx, sub_q in enumerate(data['sub_questions']):
                cursor.execute('''
                    INSERT INTO sub_questions (question_id, type, content, point, answer, explanation, position)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ''', (
                    question_id,
                    sub_q.get('type', 'problem'),
                    sub_q.get('content', ''),
                    sub_q.get('point', 1),
                    sub_q.get('answer', ''),
                    sub_q.get('explanation', ''),
                    idx
                ))
                
                sub_question_id = cursor.lastrowid
                
                if 'answers' in sub_q:
                    for a_idx, answer in enumerate(sub_q['answers']):
                        cursor.execute('''
                            INSERT INTO sub_answers (sub_question_id, content, is_correct, position)
                            VALUES (?, ?, ?, ?)
                        ''', (
                            sub_question_id,
                            answer.get('content', ''),
                            answer.get('is_correct', 0),
                            a_idx
                        ))
        
        conn.commit()
        
        content_hash = compute_question_hash(question_id)
        cursor.execute('UPDATE questions SET content_hash = ? WHERE id = ?', (content_hash, question_id))
        conn.commit()
        conn.close()
        
        self.send_json_response({'message': '题目更新成功'})
    
    def handle_delete_question(self, question_id):
        """删除题目"""
        conn = get_db()
        cursor = conn.cursor()
        
        cursor.execute('SELECT pdf_path FROM questions WHERE id = ?', (question_id,))
        question = cursor.fetchone()
        
        if question and question['pdf_path']:
            if os.path.exists(question['pdf_path']):
                os.remove(question['pdf_path'])
        
        cursor.execute('DELETE FROM questions WHERE id = ?', (question_id,))
        cursor.execute('DELETE FROM answers WHERE question_id = ?', (question_id,))
        cursor.execute('DELETE FROM question_tags WHERE question_id = ?', (question_id,))
        
        conn.commit()
        conn.close()
        
        self.send_json_response({'message': '题目删除成功'})
    
    def handle_compile_question(self, question_id):
        """编译单个题目"""
        content_length = int(self.headers.get('Content-Length', 0))
        force = False
        module_params = None

        if content_length > 0:
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            force = data.get('force', False)
            module_params = data.get('module_params', None)

        compile_result = compile_single_question(question_id, force=force, module_params=module_params)
        
        if compile_result['success']:
            message = '编译成功'
            if compile_result.get('skipped'):
                message = '题目未修改，跳过编译'
            
            self.send_json_response({
                'success': True,
                'pdf_path': compile_result['pdf_path'],
                'message': message,
                'skipped': compile_result.get('skipped', False)
            })
        else:
            self.send_json_response({
                'success': False,
                'error': compile_result['error']
            }, 500)
    
    # ---- Module parameter whitelist validation ----
    VALID_PAPERSIZES = {'A3', 'A4', 'A5', 'B5', 'ipad', 'kindle'}
    VALID_LAYOUTS = {'narrow', 'moderate', 'wide', 'extrawide', 'exotic', 'kaolike',
                     'ipad', 'kindle', 'sidemirror', 'propiorroot', 'propiorgolden', 'hermes'}
    VALID_BODYFONTS = {'adobehans', 'sourcehans', 'sinohans', 'modern'}
    VALID_FONTSIZES = {'9pt', '10pt', '11pt', '12pt', '14pt'}
    VALID_FONTSTYLES = {'rm', 'ss', 'tt'}
    VALID_THEMECOLORS = {'serene', 'harmony', 'passion', 'adventure', 'optimism',
                         'creativity', 'magic', 'romance', 'reliable', 'formality', 'innocence'}
    VALID_HDRSTYLES = {'default', 'book', 'novel', 'line', 'colorful', 'madsen', 'kaolike',
                       'rocket', 'hctext', 'fctext', 'foemargin', 'foemarginalt', 'hoemargin', 'none'}
    VALID_MODES = {'kindle', 'draft', 'print', 'moresize'}
    VALID_DOUBLESIDED = {'yes', 'no'}
    LINEHEIGHT_RE = re.compile(r'^\d+(\.\d+)?(ex|em|pt)$')

    @staticmethod
    def _validate_module_params(params):
        """Validate and sanitize module parameters. Returns sanitized dict or raises ValueError."""
        sanitized = {}
        for key, valid_set in [
            ('papersize', APIHandler.VALID_PAPERSIZES),
            ('layout', APIHandler.VALID_LAYOUTS),
            ('bodyfont', APIHandler.VALID_BODYFONTS),
            ('fontsize', APIHandler.VALID_FONTSIZES),
            ('fontstyle', APIHandler.VALID_FONTSTYLES),
            ('themecolor', APIHandler.VALID_THEMECOLORS),
            ('hdrstyle', APIHandler.VALID_HDRSTYLES),
            ('doublesided', APIHandler.VALID_DOUBLESIDED),
        ]:
            val = params.get(key, '')
            if val and val not in valid_set:
                raise ValueError(f'Invalid {key}: {val}')
            if val:
                sanitized[key] = val

        # mode: can be comma-separated multi-value
        mode_raw = params.get('mode', '')
        if mode_raw:
            modes = [m.strip() for m in mode_raw.split(',') if m.strip()]
            valid_modes = [m for m in modes if m in APIHandler.VALID_MODES]
            if valid_modes:
                sanitized['mode'] = ','.join(valid_modes)

        # margincount: integer 0-10
        mc = params.get('margincount', 0)
        try:
            mc = int(mc)
        except (ValueError, TypeError):
            mc = 0
        if mc < 0 or mc > 10:
            mc = 0
        if mc != 0:
            sanitized['margincount'] = mc

        # textcount: integer 10-100
        tc = params.get('textcount', 0)
        try:
            tc = int(tc)
        except (ValueError, TypeError):
            tc = 0
        if tc >= 10 and tc <= 100:
            sanitized['textcount'] = tc

        # heightcount: integer 10-100
        hc = params.get('heightcount', 0)
        try:
            hc = int(hc)
        except (ValueError, TypeError):
            hc = 0
        if hc >= 10 and hc <= 100:
            sanitized['heightcount'] = hc

        # lineheight: pattern check
        lh = params.get('lineheight', '')
        if lh and APIHandler.LINEHEIGHT_RE.match(lh):
            sanitized['lineheight'] = lh

        return sanitized

    @staticmethod
    def _build_module_str(params):
        r"""Build \usemodule[memos][...] parameter string from sanitized params."""
        parts = ['mainlanguage=hans']  # always include
        # Always include all params that have a value (even if they match defaults)
        for key in ('bodyfont', 'papersize', 'layout', 'fontsize', 'fontstyle',
                    'doublesided', 'themecolor', 'hdrstyle', 'lineheight'):
            if params.get(key):
                parts.append(f'{key}={params[key]}')
        # mode: can be comma-separated multi-value
        if params.get('mode'):
            for m in params['mode'].split(','):
                if m:
                    parts.append(f'mode={m}')
        # Hermes-specific integer params (only when layout=hermes)
        if params.get('layout') == 'hermes':
            if params.get('textcount'):
                parts.append(f'textcount={params["textcount"]}')
            if params.get('heightcount'):
                parts.append(f'heightcount={params["heightcount"]}')
            if params.get('margincount'):
                parts.append(f'margincount={params["margincount"]}')
        return ','.join(parts)

    @staticmethod
    def _generate_export_content(question_ids, show_answer, show_more, module_params):
        """Generate .tex content for export. Returns the full .tex string."""
        conn = get_db()
        cursor = conn.cursor()

        module_str = APIHandler._build_module_str(module_params)
        content = f"\\usemodule[memos][{module_str}]\n"
        content += "\\usemodule[basicexam]\n"
        content += "\\starttext\n\n"

        if show_answer:
            content += "\\enableshowanswer\n"
        if show_more:
            content += "\\enableshowmore\n"
        content += "\n"

        for qid in question_ids:
            cursor.execute('SELECT * FROM questions WHERE id = ?', (qid,))
            question = cursor.fetchone()
            if not question:
                continue
            question_dict = dict(question)
            question_dict['id'] = qid
            content += generate_question_tex(question_dict, cursor, show_answer, show_more)

        content += "\\stoptext"
        conn.close()
        return content

    def handle_export(self):
        """导出选中的题目为tex格式"""
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        data = json.loads(post_data.decode('utf-8'))

        question_ids = data.get('question_ids', [])
        show_answer = data.get('show_answer', True)
        show_more = data.get('show_more', True)

        if not question_ids:
            self.send_json_response({'error': '未选择题目'}, 400)
            return

        try:
            module_params = self._validate_module_params(data)
            content = self._generate_export_content(question_ids, show_answer, show_more, module_params)

            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            filename = f'exported_questions_{timestamp}.tex'

            self.send_response(200)
            self.send_header('Content-type', 'application/octet-stream')
            self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
            self.end_headers()
            self.wfile.write(content.encode('utf-8'))

            logger.info(f"成功导出 {len(question_ids)} 个题目 (tex)")

        except ValueError as e:
            logger.error(f"导出参数校验失败: {e}")
            self.send_json_response({'error': str(e)}, 400)
        except Exception as e:
            logger.error(f"导出失败: {e}")
            self.send_json_response({'error': str(e)}, 500)

    def handle_export_pdf(self):
        """导出选中的题目编译为PDF格式"""
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        data = json.loads(post_data.decode('utf-8'))

        question_ids = data.get('question_ids', [])
        show_answer = data.get('show_answer', True)
        show_more = data.get('show_more', True)

        if not question_ids:
            self.send_json_response({'error': '未选择题目'}, 400)
            return

        context_file = None
        try:
            module_params = self._validate_module_params(data)
            content = self._generate_export_content(question_ids, show_answer, show_more, module_params)

            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            context_file = f'export_{timestamp}.tex'
            pdf_file = f'export_{timestamp}.pdf'

            with open(context_file, 'w', encoding='utf-8') as f:
                f.write(content)

            result = subprocess.run(
                ['context', '--purge', context_file],
                capture_output=True, text=True, timeout=120
            )

            if result.returncode == 0 and os.path.exists(pdf_file):
                with open(pdf_file, 'rb') as f:
                    pdf_data = f.read()

                filename = f'exported_questions_{timestamp}.pdf'
                self.send_response(200)
                self.send_header('Content-type', 'application/pdf')
                self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
                self.end_headers()
                self.wfile.write(pdf_data)

                logger.info(f"成功导出 {len(question_ids)} 个题目 (pdf)")
            else:
                error_msg = result.stderr if result.stderr else f"编译失败，返回码: {result.returncode}"
                logger.error(f"PDF导出编译失败: {error_msg}")
                self.send_json_response({'error': error_msg}, 500)

        except subprocess.TimeoutExpired:
            logger.error("PDF导出编译超时")
            self.send_json_response({'error': '编译超时（120秒）'}, 500)
        except ValueError as e:
            logger.error(f"导出参数校验失败: {e}")
            self.send_json_response({'error': str(e)}, 400)
        except Exception as e:
            logger.error(f"PDF导出失败: {e}")
            self.send_json_response({'error': str(e)}, 500)
        finally:
            if context_file:
                for ext in ['.tex', '.tuc', '.log', '.aux', '.out', '.toc', '.pdf']:
                    temp_file = context_file.replace('.tex', ext)
                    if os.path.exists(temp_file):
                        try:
                            os.remove(temp_file)
                        except Exception:
                            pass
    
    def handle_compile(self):
        """编译多个题目"""
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        data = json.loads(post_data.decode('utf-8'))

        question_ids = data.get('question_ids', [])
        module_params = data.get('module_params', None)
        
        if not question_ids:
            self.send_json_response({'error': '未选择题目'}, 400)
            return
        
        results = []
        conn = get_db()
        cursor = conn.cursor()
        
        try:
            for qid in question_ids:
                cursor.execute('SELECT * FROM questions WHERE id = ?', (qid,))
                question = cursor.fetchone()
                
                if not question:
                    results.append({'id': qid, 'status': 'error', 'message': '题目不存在'})
                    continue
                
                current_hash = compute_question_hash(qid)
                
                if question['content_hash'] == current_hash and question['pdf_path']:
                    if os.path.exists(question['pdf_path']):
                        results.append({
                            'id': qid, 
                            'status': 'cached',
                            'pdf_url': f'/cache/{os.path.basename(question["pdf_path"])}'
                        })
                        continue
                
                compile_result = compile_single_question(qid, module_params=module_params)
                
                if compile_result['success']:
                    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                    cursor.execute('UPDATE questions SET pdf_path = ?, compiled_at = ?, content_hash = ? WHERE id = ?', 
                                  (compile_result['pdf_path'], now, current_hash, qid))
                    conn.commit()
                    
                    results.append({
                        'id': qid,
                        'status': 'success',
                        'pdf_url': f'/cache/{os.path.basename(compile_result["pdf_path"])}'
                    })
                else:
                    cursor.execute('UPDATE questions SET pdf_path = NULL, compiled_at = NULL WHERE id = ?', (qid,))
                    conn.commit()
                    
                    results.append({
                        'id': qid,
                        'status': 'error',
                        'message': compile_result['error']
                    })
            
            success_count = sum(1 for r in results if r['status'] in ['success', 'cached'])
            
            self.send_json_response({
                'results': results,
                'message': f'成功编译 {success_count}/{len(question_ids)} 道题目'
            })
        except Exception as e:
            print(f"批量编译异常: {str(e)}")
            self.send_json_response({
                'error': str(e),
                'message': f'批量编译异常: {str(e)}'
            }, 500)
        finally:
            conn.close()
    
    def handle_get_pdf(self, filename):
        """获取PDF文件"""
        pdf_path = os.path.join(CACHE_DIR, filename)
        
        if not os.path.exists(pdf_path):
            self.send_error(404, "PDF not found")
            return
        
        with open(pdf_path, 'rb') as f:
            pdf_data = f.read()
        
        self.send_response(200)
        self.send_header('Content-Type', 'application/pdf')
        self.send_header('Content-Length', len(pdf_data))
        self.end_headers()
        self.wfile.write(pdf_data)
    
    def send_json_response(self, data, status=200):
        """发送JSON响应"""
        response = json.dumps(data, ensure_ascii=False)
        
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', len(response.encode('utf-8')))
        self.end_headers()
        self.wfile.write(response.encode('utf-8'))
    
    def log_message(self, format, *args):
        """自定义日志格式"""
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {args[0]}")

def main():
    """主函数"""
    logger.info("=" * 50)
    logger.info("题目管理系统启动")
    logger.info("=" * 50)
    
    print("初始化数据库...")
    init_database()
    print("✅ 数据库初始化完成")
    
    print("清理缓存...")
    cleaned = clean_cache()
    if cleaned > 0:
        print(f"✅ 清理了 {cleaned} 个缓存文件")
    else:
        print("✅ 缓存无需清理")
    
    PORT = 8080
    
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", PORT), APIHandler) as httpd:
        logger.info(f"服务启动: http://localhost:{PORT}")
        print(f"🌐 服务启动: http://localhost:{PORT}")
        print(f"📝 日志文件: {LOG_FILE}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            logger.info("服务停止")
            print("\n👋 服务停止")
        except Exception as e:
            logger.error(f"服务异常: {str(e)}")
            raise

if __name__ == '__main__':
    main()
