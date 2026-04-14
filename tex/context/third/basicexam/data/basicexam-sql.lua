if not modules then modules = { } end modules ['basicexam-sql'] = {
    version   = 1.001,
    comment   = "basicexam SQLite database module",
}

local sqlitelib = resolvers.libraries.validoptional("sqlite")

thirddata = thirddata or { }
thirddata.basicexam_sql = thirddata.basicexam_sql or { }
local basicexam_sql = thirddata.basicexam_sql

local current_material_shown = nil

if not sqlitelib then
    return basicexam_sql
end

if not basicexam_sql.libfile then
    basicexam_sql.libfile = ""
end

if not basicexam_sql.set_libpath then
    function basicexam_sql.set_libpath(path)
        basicexam_sql.libfile = path
    end
end

local function okay()
    local libfile = basicexam_sql.libfile
    if libfile and libfile ~= "" then
        if resolvers.libraries.optionalloaded("sqlite", libfile) then
            return true
        end
    end
    return false
end

local report = logs.reporter("basicexam-sql")

local sqlite_open        = sqlitelib.open
local sqlite_close       = sqlitelib.close
local sqlite_execute     = sqlitelib.execute
local sqlite_getmessage  = sqlitelib.getmessage

local format = string.format
local concat = table.concat
local context = context

local SCHEMA = [[
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

CREATE INDEX IF NOT EXISTS idx_questions_type ON questions(type);
CREATE INDEX IF NOT EXISTS idx_questions_material ON questions(material_id);
CREATE INDEX IF NOT EXISTS idx_answers_question ON answers(question_id);
CREATE INDEX IF NOT EXISTS idx_answers_position ON answers(position);
CREATE INDEX IF NOT EXISTS idx_question_tags_tag ON question_tags(tag);
CREATE INDEX IF NOT EXISTS idx_question_tags_question ON question_tags(question_id);
]]

basicexam_sql.SCHEMA = SCHEMA

function basicexam_sql.open_database(dbpath)
    if not okay() then
        report("error: SQLite library not loaded")
        return nil
    end
    
    local db = sqlite_open(dbpath)
    if not db then
        report("error: cannot open database %s", dbpath)
        return nil
    end
    
    sqlite_execute(db, SCHEMA)
    
    return db
end

function basicexam_sql.close_database(db)
    if db then
        sqlite_close(db)
    end
end

local function execute_query(db, query, callback)
    if not db then
        report("error: no database connection")
        return nil
    end
    
    local result = { }
    local fields_cache = nil
    
    local cb = callback or function(nofcolumns, values, fields)
        if fields then
            fields_cache = fields
        end
        
        local row = { }
        for i = 1, nofcolumns do
            local field = fields_cache and fields_cache[i]
            if field then
                row[field] = values[i]
            end
            row[i] = values[i]
        end
        result[#result + 1] = row
    end
    
    local ok = sqlite_execute(db, query, cb)
    if not ok then
        report("error: %s", sqlite_getmessage(db))
        return nil
    end
    
    return result
end

function basicexam_sql.add_material(db, data)
    local title = data.title or ""
    local content = data.content or ""
    local author = data.author or ""
    local source = data.source or ""
    
    local query = format(
        [[INSERT INTO materials (title, content, author, source)
        VALUES ('%s', '%s', '%s', '%s')]],
        title:gsub("'", "''"), content:gsub("'", "''"),
        author:gsub("'", "''"), source:gsub("'", "''")
    )
    
    execute_query(db, query)
    
    local result = execute_query(db, "SELECT last_insert_rowid() as id")
    return result and result[1] and result[1].id
end

function basicexam_sql.get_material(db, material_id)
    local query = format(
        [[SELECT * FROM materials WHERE id = %s]],
        material_id
    )
    local result = execute_query(db, query)
    return result and result[1]
end

function basicexam_sql.get_all_materials(db)
    local query = [[SELECT * FROM materials ORDER BY id]]
    return execute_query(db, query)
end

function basicexam_sql.get_material_by_title(db, title)
    local query = format(
        [[SELECT * FROM materials WHERE title = '%s']],
        title:gsub("'", "''")
    )
    local result = execute_query(db, query)
    return result and result[1]
end

function basicexam_sql.add_question(db, data)
    local qtype = data.type or "problem"
    local content = data.content or ""
    local point = data.point or 1
    local answer = data.answer or ""
    local explanation = data.explanation or ""
    local material_id = data.material_id
    local source = data.source or ""
    local year = data.year or "NULL"
    local difficulty = data.difficulty or 1
    
    local query
    if material_id then
        query = format(
            [[INSERT INTO questions (type, content, point, answer, explanation, material_id, source, year, difficulty)
            VALUES ('%s', '%s', %s, '%s', '%s', %s, '%s', %s, %s)]],
            qtype, content:gsub("'", "''"), point, answer:gsub("'", "''"),
            explanation:gsub("'", "''"), material_id, source:gsub("'", "''"), year, difficulty
        )
    else
        query = format(
            [[INSERT INTO questions (type, content, point, answer, explanation, source, year, difficulty)
            VALUES ('%s', '%s', %s, '%s', '%s', '%s', %s, %s)]],
            qtype, content:gsub("'", "''"), point, answer:gsub("'", "''"),
            explanation:gsub("'", "''"), source:gsub("'", "''"), year, difficulty
        )
    end
    
    execute_query(db, query)
    
    local result = execute_query(db, "SELECT last_insert_rowid() as id")
    return result and result[1] and result[1].id
end

function basicexam_sql.add_question_tag(db, question_id, tag)
    local query = format(
        [[INSERT INTO question_tags (question_id, tag) VALUES (%s, '%s')]],
        question_id, tag:gsub("'", "''")
    )
    return execute_query(db, query)
end

function basicexam_sql.add_answer(db, question_id, content, is_correct, position, answer, explanation)
    local query = format(
        [[INSERT INTO answers (question_id, content, answer, explanation, is_correct, position)
        VALUES (%s, '%s', '%s', '%s', %s, %s)]],
        question_id, content:gsub("'", "''"),
        (answer or ""):gsub("'", "''"),
        (explanation or ""):gsub("'", "''"),
        is_correct and 1 or 0, position or 0
    )
    return execute_query(db, query)
end

function basicexam_sql.add_choice(db, question_id, label, content, is_correct, position)
    return basicexam_sql.add_answer(db, question_id, content, is_correct, position)
end

function basicexam_sql.get_answers(db, question_id)
    local query = format(
        [[SELECT * FROM answers WHERE question_id = %s ORDER BY position, id]],
        question_id
    )
    return execute_query(db, query)
end

function basicexam_sql.get_answer_by_id(db, answer_id)
    local query = format(
        [[SELECT * FROM answers WHERE id = %s]],
        answer_id
    )
    local result = execute_query(db, query)
    return result and result[1]
end

function basicexam_sql.get_choices(db, question_id)
    return basicexam_sql.get_answers(db, question_id)
end

function basicexam_sql.get_questions_by_material(db, material_id)
    local query = format(
        [[SELECT * FROM questions WHERE material_id = %s ORDER BY id]],
        material_id
    )
    return execute_query(db, query)
end

function basicexam_sql.search_questions(db, filters)
    local conditions = {}
    
    if filters.id and filters.id ~= "" then
        conditions[#conditions + 1] = format("q.id = %s", filters.id)
    end
    
    if filters.tag and filters.tag ~= "" then
        local tag_str = filters.tag
        if tag_str:find("%+") then
            for t in string.gmatch(tag_str, "[^+]+") do
                local trimmed = t:gsub("^%s*(.-)%s*$", "%1")
                if trimmed ~= "" then
                    conditions[#conditions + 1] = format(
                        [[EXISTS (SELECT 1 FROM question_tags qt WHERE qt.question_id = q.id AND qt.tag = '%s')]],
                        trimmed:gsub("'", "''")
                    )
                end
            end
        elseif tag_str:find(",") then
            local or_conditions = {}
            for t in string.gmatch(tag_str, "[^,]+") do
                local trimmed = t:gsub("^%s*(.-)%s*$", "%1")
                if trimmed ~= "" then
                    or_conditions[#or_conditions + 1] = format(
                        [[EXISTS (SELECT 1 FROM question_tags qt WHERE qt.question_id = q.id AND qt.tag = '%s')]],
                        trimmed:gsub("'", "''")
                    )
                end
            end
            if #or_conditions > 0 then
                conditions[#conditions + 1] = "(" .. concat(or_conditions, " OR ") .. ")"
            end
        elseif tag_str:sub(1,1) == "-" then
            local trimmed = tag_str:sub(2):gsub("^%s*(.-)%s*$", "%1")
            if trimmed ~= "" then
                conditions[#conditions + 1] = format(
                    [[NOT EXISTS (SELECT 1 FROM question_tags qt WHERE qt.question_id = q.id AND qt.tag = '%s')]],
                    trimmed:gsub("'", "''")
                )
            end
        else
            conditions[#conditions + 1] = format(
                [[EXISTS (SELECT 1 FROM question_tags qt WHERE qt.question_id = q.id AND qt.tag = '%s')]],
                tag_str:gsub("'", "''")
            )
        end
    end
    
    if filters.year and filters.year ~= "" then
        conditions[#conditions + 1] = format("q.year = %s", filters.year)
    end
    
    if filters.source and filters.source ~= "" then
        conditions[#conditions + 1] = format("q.source = '%s'", filters.source:gsub("'", "''"))
    end
    
    if filters.type and filters.type ~= "" then
        conditions[#conditions + 1] = format("q.type = '%s'", filters.type)
    end
    
    local where_clause = ""
    if #conditions > 0 then
        where_clause = " WHERE " .. concat(conditions, " AND ")
    end
    
    local query = format(
        [[SELECT q.* FROM questions q%s ORDER BY q.id]],
        where_clause
    )
    return execute_query(db, query)
end

function basicexam_sql.get_all_questions(db)
    local query = [[SELECT * FROM questions ORDER BY id]]
    return execute_query(db, query)
end

function basicexam_sql.get_question_tags(db, question_id)
    local query = format(
        [[SELECT tag FROM question_tags WHERE question_id = %s]],
        question_id
    )
    local result = execute_query(db, query)
    if result then
        local tags = {}
        for i, row in ipairs(result) do
            tags[#tags + 1] = row.tag or row[1]
        end
        return concat(tags, ", ")
    end
    return ""
end

function basicexam_sql.render_questions_table(db, questions)
    context("\\tfx")
    context.startxtable { "xtable:questions" }
    context.startxtablehead()
    context.startxrow { "bottomframe=on" }
    context.startxcell { "xcell:header" } context.bold("ID") context.stopxcell()
    context.startxcell { "xcell:header" } context.bold("Type") context.stopxcell()
    context.startxcell { "xcell:header" } context.bold("Content") context.stopxcell()
    context.startxcell { "xcell:header" } context.bold("Qitem IDs") context.stopxcell()
    context.startxcell { "xcell:header" } context.bold("Tags") context.stopxcell()
    context.startxcell { "xcell:header" } context.bold("Year") context.stopxcell()
    context.startxcell { "xcell:header" } context.bold("Source") context.stopxcell()
    context.startxcell { "xcell:header" } context.bold("Point") context.stopxcell()
    context.stopxrow()
    context.stopxtablehead()
    context.startxtablebody()
    for i, q in ipairs(questions) do
        local tags = basicexam_sql.get_question_tags(db, q.id)
        local content = (q.content or ""):sub(1, 40)
        if (q.content or ""):len() > 40 then
            content = content .. "..."
        end
        local qitems = basicexam_sql.get_answers(db, q.id)
        local qitem_ids = ""
        if qitems and #qitems > 0 then
            local ids = {}
            for j, p in ipairs(qitems) do
                ids[#ids + 1] = tostring(p.id)
            end
            qitem_ids = concat(ids, ",")
        end
        context.startxrow()
        context.startxcell() context(q.id or "") context.stopxcell()
        context.startxcell() context(q.type or "") context.stopxcell()
        context.startxcell() context(content) context.stopxcell()
        context.startxcell() context(qitem_ids) context.stopxcell()
        context.startxcell() context(tags or "") context.stopxcell()
        context.startxcell() context(q.year or "") context.stopxcell()
        context.startxcell() context(q.source or "") context.stopxcell()
        context.startxcell() context(q.point or "1") context.stopxcell()
        context.stopxrow()
    end
    context.stopxtablebody()
    context.stopxtable()
end

function basicexam_sql.delete_question(db, question_id)
    local query = format([[DELETE FROM questions WHERE id = %s]], question_id)
    return execute_query(db, query)
end

function basicexam_sql.update_question(db, question_id, data)
    local sets = { }
    
    if data.type then
        sets[#sets + 1] = format("type = '%s'", data.type)
    end
    if data.content then
        sets[#sets + 1] = format("content = '%s'", data.content:gsub("'", "''"))
    end
    if data.point then
        sets[#sets + 1] = format("point = %s", data.point)
    end
    if data.answer then
        sets[#sets + 1] = format("answer = '%s'", data.answer:gsub("'", "''"))
    end
    if data.explanation then
        sets[#sets + 1] = format("explanation = '%s'", data.explanation:gsub("'", "''"))
    end
    if data.source then
        sets[#sets + 1] = format("source = '%s'", data.source:gsub("'", "''"))
    end
    if data.year then
        sets[#sets + 1] = format("year = %s", data.year)
    end
    
    if #sets > 0 then
        local query = format(
            [[UPDATE questions SET %s WHERE id = %s]],
            concat(sets, ", "), question_id
        )
        return execute_query(db, query)
    end
end

function basicexam_sql.render_material(m, options)
    options = options or {}
    local params = {}
    if m.title and m.title ~= "" then
        params.title = m.title
    end
    if m.author and m.author ~= "" then
        params.author = m.author
    end
    if m.source and m.source ~= "" then
        params.source = m.source
    end
    context.startmaterial(params)
    context(m.content or "")
    context.stopmaterial()
end

function basicexam_sql.render_material_with_questions(db, m, options)
    options = options or {}
    basicexam_sql.render_material(m, options)
    current_material_shown = m.id
    
    local questions = basicexam_sql.get_questions_by_material(db, m.id)
    if questions then
        for i, q in ipairs(questions) do
            basicexam_sql.render_question(db, q, options)
        end
    end
end

function basicexam_sql.reset_material_shown()
    current_material_shown = nil
end

function basicexam_sql.render_question(db, q, options)
    options = options or { }
    
    if q.material_id and current_material_shown ~= q.material_id then
        local m = basicexam_sql.get_material(db, q.material_id)
        if m then
            basicexam_sql.render_material(m, options)
            current_material_shown = q.material_id
        end
    end
    
    local qtype = q.type or "question"
    
    if qtype == "choice" then
        basicexam_sql.render_choice_question(db, q, options)
    elseif qtype == "writing" then
        basicexam_sql.render_writing_question(db, q, options)
    else
        basicexam_sql.render_question_content(db, q, options)
    end
end

local function build_question_params(q, options)
    local showanswer = options.showanswer and "true" or "false"
    local showpoint = options.showpoint ~= false and "true" or "false"
    local point = tonumber(q.point) or 1
    local answer = q.answer or ""
    
    local params = "showanswer=" .. showanswer .. ",showpoint=" .. showpoint .. ",point=" .. point
    if answer and answer ~= "" then
        params = params .. ",answer={" .. answer .. "}"
    end
    
    local moreinfo = ""
    if q.source and q.source ~= "" then
        moreinfo =  q.source
    end
    if q.year and q.year ~= "" then
        if moreinfo ~= "" then
            moreinfo = moreinfo .. ", "
        end
        moreinfo = moreinfo .. q.year
    end
    if moreinfo ~= "" then
        params = params .. ",showmore=true,moreinfo={" .. moreinfo .. "}"
    end
    
    return params
end

local function render_explanation(explanation, showanswer)
    if explanation and explanation ~= "" and showanswer then
        context("\\answer{" .. explanation .. "}")
    end
end

local function render_pitem(p, showanswer)
    local pitem_answer = p.answer or ""
    context("\\startpitem[answer={" .. pitem_answer .. "}]")
    context(p.content or "")
    render_explanation(p.explanation, showanswer)
    context("\\stoppitem")
end

local function render_simple_question(params, q, showanswer)
    context("\\startquestion[" .. params .. "]")
    context(q.content or "")
    render_explanation(q.explanation, showanswer)
    context("\\stopquestion")
end

function basicexam_sql.render_choice_question(db, q, options)
    options = options or {}
    context("\\startquestion[" .. build_question_params(q, options) .. "]")
    context(q.content or "")
    
    local choices = basicexam_sql.get_choices(db, q.id)
    if choices and #choices > 0 then
        context("\\startchoice")
        for i, c in ipairs(choices) do
            local is_correct = c.is_correct == "1"
            if is_correct then
                context("\\startcitem[*] " .. (c.content or "") .. "\\stopcitem")
            else
                context("\\startcitem " .. (c.content or "") .. "\\stopcitem")
            end
        end
        context("\\stopchoice")
    end
    
    render_explanation(q.explanation, options.showanswer)
    context("\\stopquestion")
end

function basicexam_sql.render_question_content(db, q, options)
    options = options or {}
    local params = build_question_params(q, options)
    local qitemid = options.qitemid
    
    if qitemid then
        local qitem = basicexam_sql.get_answer_by_id(db, qitemid)
        if qitem then
            context("\\startquestion[" .. params .. "]")
            context(q.content or "")
            context("\\startproblem")
            render_pitem(qitem, options.showanswer)
            context("\\stopproblem")
            context("\\stopquestion")
        end
    else
        local pitems = basicexam_sql.get_answers(db, q.id)
        if pitems and #pitems > 0 then
            context("\\startquestion[" .. params .. "]")
            context(q.content or "")
            context("\\startproblem")
            for i, p in ipairs(pitems) do
                render_pitem(p, options.showanswer)
            end
            context("\\stopproblem")
            context("\\stopquestion")
        else
            render_simple_question(params, q, options.showanswer)
        end
    end
end

function basicexam_sql.render_writing_question(db, q, options)
    options = options or {}
    local params = build_question_params(q, options)
    
    local pitems = basicexam_sql.get_answers(db, q.id)
    if pitems and #pitems > 0 then
        context("\\startwriting[" .. params .. "]")
        context(q.content or "")
        for i, p in ipairs(pitems) do
            local pitem_answer = p.answer or ""
            context("\\startsubwriting[answer={" .. pitem_answer .. "}]")
            context(p.content or "")
            render_explanation(p.explanation, options.showanswer)
            context("\\stopsubwriting")
        end
        context("\\stopwriting")
    else
        context("\\startwriting[" .. params .. "]")
        context(q.content or "")
        render_explanation(q.explanation, options.showanswer)
        context("\\stopwriting")
    end
end
