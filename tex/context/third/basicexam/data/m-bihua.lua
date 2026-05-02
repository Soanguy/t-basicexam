thirddata = thirddata or {}
thirddata.bihua = thirddata.bihua or {}
local bihua = thirddata.bihua

local loaded_chars = {}
local data_dir = "data-bihua"
local current_options = {}

function bihua.set_data_dir(dir)
    data_dir = dir
end

function bihua.set_options(opts)
    current_options = opts or {}
    local function parse_dim(s)
        if type(s) == "number" then return s end
        if not s or s == "" then return 0 end
        local num = s:match("([%d.]+)")
        return tonumber(num) or 0
    end
    current_options.width = parse_dim(opts.width) or 10
    current_options.spacing = parse_dim(opts.spacing) or 0
    current_options.frame_linewidth = parse_dim(opts.frame_linewidth) or 0.5
    current_options.iframe_linewidth = parse_dim(opts.iframe_linewidth) or 0.3
    current_options.char_linewidth = parse_dim(opts.char_linewidth) or 0.3
    current_options.last_linewidth = parse_dim(opts.last_linewidth) or 0.3
    current_options.inner_t = parse_dim(opts.inner_t) or 0
    current_options.inner_b = parse_dim(opts.inner_b) or 0
    current_options.inner_l = parse_dim(opts.inner_l) or 0
    current_options.inner_r = parse_dim(opts.inner_r) or 0
    if opts.inner and opts.inner ~= "" then
        local v = parse_dim(opts.inner)
        current_options.inner_t = v
        current_options.inner_b = v
        current_options.inner_l = v
        current_options.inner_r = v
    end
    local nat = opts.natural
    if type(nat) == "string" then
        current_options.natural = (nat == "yes" or nat == "true")
    end
end

local function split_path(path_str)
    local parts = {}
    local current = ""
    for i = 1, #path_str do
        local c = path_str:sub(i, i)
        if c:match("[MmLlHhVvCcSsQqTtAaZz]") then
            if #current > 0 then table.insert(parts, current) end
            current = c
        elseif c == " " or c == "," then
            if #current > 0 then table.insert(parts, current); current = "" end
        else
            current = current .. c
        end
    end
    if #current > 0 then table.insert(parts, current) end
    return parts
end

local function parse_stroke_path(path_str)
    local strokes = {}
    local parts = split_path(path_str)
    local current_stroke = {}
    local cmd, nums = nil, {}
    
    for _, part in ipairs(parts) do
        if part:match("^[MmLlHhVvCcSsQqTtAaZz]$") then
            if cmd and #nums > 0 then table.insert(current_stroke, {cmd = cmd, nums = nums}) end
            if part:upper() == "Z" then
                table.insert(current_stroke, {cmd = "Z", nums = {}})
                if #current_stroke > 0 then table.insert(strokes, current_stroke); current_stroke = {} end
            end
            cmd, nums = part, {}
        else
            local n = tonumber(part)
            if n then table.insert(nums, n) end
        end
    end
    if cmd and #nums > 0 then table.insert(current_stroke, {cmd = cmd, nums = nums}) end
    if #current_stroke > 0 then table.insert(strokes, current_stroke) end
    return strokes
end

local function extract_strokes(content)
    local strokes = {}
    local match_start = content:find("\\HZBH{")
    if not match_start then return strokes end
    
    local after_cmd = content:find("}", match_start + 6)
    if not after_cmd then return strokes end
    
    local data_start = content:find("{", after_cmd + 1)
    if not data_start then return strokes end
    
    local depth, current_stroke, in_stroke = 0, {}, false
    for i = data_start + 1, #content do
        local c = content:sub(i, i)
        if c == "{" then
            if depth == 0 then in_stroke = true; current_stroke = {} end
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 and in_stroke then
                local stroke_str = table.concat(current_stroke):match("^%s*(.-)%s*$")
                if #stroke_str > 0 then
                    for _, s in ipairs(parse_stroke_path(stroke_str)) do
                        table.insert(strokes, s)
                    end
                end
                in_stroke = false
            end
        elseif in_stroke then
            table.insert(current_stroke, c)
        end
    end
    return strokes
end

function bihua.load_char(char, custom_data_path)
    local data_path = custom_data_path or data_dir
    local code = utf8.codepoint(char)
    
    if loaded_chars[code] then return loaded_chars[code] end
    
    local filename = string.format("%s/%d.txt", data_path, code)
    local file = io.open(filename, "r")
    if not file then return nil, "Cannot find stroke data for: " .. char end
    
    local content = file:read("*all")
    file:close()
    
    local strokes = extract_strokes(content)
    loaded_chars[code] = { char = char, code = code, strokes = strokes, count = #strokes }
    return loaded_chars[code]
end

function bihua.load_chars(chars, data_path)
    for char in chars:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        bihua.load_char(char, data_path)
    end
end

function bihua.get_char(char)
    return loaded_chars[utf8.codepoint(char)]
end

function bihua.stroke_count(char)
    local data = bihua.get_char(char)
    return data and data.count or 0
end

local function stroke_to_metafun(stroke, scale, offset_x)
    offset_x = offset_x or 0
    local y_offset = 124
    local function tx(x) return x * scale + offset_x end
    local function ty(y) return (y + y_offset) * scale end
    
    local mp, x, y = {}, 0, 0
    table.insert(mp, "path p; p := origin;")
    
    for _, seg in ipairs(stroke) do
        local cmd, nums, rel = seg.cmd:upper(), seg.nums, seg.cmd:lower() == seg.cmd
        
        if cmd == "M" then
            x, y = rel and x + nums[1] or nums[1], rel and y + nums[2] or nums[2]
            table.insert(mp, string.format("p := (%f, %f);", tx(x), ty(y)))
        elseif cmd == "L" then
            x, y = rel and x + nums[1] or nums[1], rel and y + nums[2] or nums[2]
            table.insert(mp, string.format("p := p -- (%f, %f);", tx(x), ty(y)))
        elseif cmd == "H" then
            x = rel and x + nums[1] or nums[1]
            table.insert(mp, string.format("p := p -- (%f, %f);", tx(x), ty(y)))
        elseif cmd == "V" then
            y = rel and y + nums[1] or nums[1]
            table.insert(mp, string.format("p := p -- (%f, %f);", tx(x), ty(y)))
        elseif cmd == "Q" then
            local i = 1
            while i < #nums do
                local qx, qy, px, py
                if rel then qx, qy, px, py = x + nums[i], y + nums[i+1], x + nums[i+2], y + nums[i+3]
                else qx, qy, px, py = nums[i], nums[i+1], nums[i+2], nums[i+3] end
                table.insert(mp, string.format("p := p .. controls (%f, %f) .. (%f, %f);", tx(qx), ty(qy), tx(px), ty(py)))
                x, y, i = px, py, i + 4
            end
        elseif cmd == "C" then
            local i = 1
            while i < #nums do
                local c1x, c1y, c2x, c2y, px, py
                if rel then c1x, c1y, c2x, c2y, px, py = x + nums[i], y + nums[i+1], x + nums[i+2], y + nums[i+3], x + nums[i+4], y + nums[i+5]
                else c1x, c1y, c2x, c2y, px, py = nums[i], nums[i+1], nums[i+2], nums[i+3], nums[i+4], nums[i+5] end
                table.insert(mp, string.format("p := p .. controls (%f, %f) and (%f, %f) .. (%f, %f);", tx(c1x), ty(c1y), tx(c2x), ty(c2y), tx(px), ty(py)))
                x, y, i = px, py, i + 6
            end
        elseif cmd == "Z" then
            table.insert(mp, "p := p -- cycle;")
        end
    end
    return table.concat(mp, "\n  ")
end

local function dash_to_mp(pattern, lw)
    if pattern == "solid" then return ""
    elseif pattern == "dotted" then return string.format(" dashed dashpattern(on 0 off %f)", lw * 2)
    elseif pattern == "dashed" then return " dashed evenly"
    else return "" end
end

local function draw_frame(mp, opts, offset_x)
    offset_x = offset_x or 0
    local w = opts.width
    local frame = opts.frame
    local natural = opts.natural
    if natural then return end
    
    local x0, y0 = offset_x - opts.inner_l, -opts.inner_b
    local x1, y1 = offset_x + w + opts.inner_r, w + opts.inner_t
    local flw = opts.frame_linewidth
    local ilw = opts.iframe_linewidth
    local fdp = dash_to_mp(opts.frame_dashpattern, flw)
    local idp = dash_to_mp(opts.iframe_dashpattern, ilw)
    
    if frame == "outer" or frame == "outerx" or frame == "outertian" or frame == "outermi" then
        if opts.frame_fill and opts.frame_fill ~= "" then
            table.insert(mp, string.format("  fill (%f,%f) -- (%f,%f) -- (%f,%f) -- (%f,%f) -- cycle withcolor %s;", x0, y0, x1, y0, x1, y1, x0, y1, opts.frame_fill))
        end
        table.insert(mp, string.format("  draw (%f,%f) -- (%f,%f) -- (%f,%f) -- (%f,%f) -- cycle withpen pencircle scaled %fpt%s withcolor %s;", x0, y0, x1, y0, x1, y1, x0, y1, flw, fdp, opts.frame_stroke))
    end
    
    if frame == "x" or frame == "outerx" then
        table.insert(mp, string.format("  draw (%f,%f) -- (%f,%f) withpen pencircle scaled %fpt%s withcolor %s;", x0, y0, x1, y1, ilw, idp, opts.iframe_stroke))
        table.insert(mp, string.format("  draw (%f,%f) -- (%f,%f) withpen pencircle scaled %fpt%s withcolor %s;", x0, y1, x1, y0, ilw, idp, opts.iframe_stroke))
    end
    
    if frame == "tian" or frame == "outertian" then
        table.insert(mp, string.format("  draw (%f,%f) -- (%f,%f) withpen pencircle scaled %fpt%s withcolor %s;", x0, w/2, x1, w/2, ilw, idp, opts.iframe_stroke))
        table.insert(mp, string.format("  draw (%f,%f) -- (%f,%f) withpen pencircle scaled %fpt%s withcolor %s;", offset_x + w/2, y0, offset_x + w/2, y1, ilw, idp, opts.iframe_stroke))
    end
    
    if frame == "mi" or frame == "outermi" then
        table.insert(mp, string.format("  draw (%f,%f) -- (%f,%f) withpen pencircle scaled %fpt%s withcolor %s;", x0, w/2, x1, w/2, ilw, idp, opts.iframe_stroke))
        table.insert(mp, string.format("  draw (%f,%f) -- (%f,%f) withpen pencircle scaled %fpt%s withcolor %s;", offset_x + w/2, y0, offset_x + w/2, y1, ilw, idp, opts.iframe_stroke))
        table.insert(mp, string.format("  draw (%f,%f) -- (%f,%f) withpen pencircle scaled %fpt%s withcolor %s;", x0, y0, x1, y1, ilw, idp, opts.iframe_stroke))
        table.insert(mp, string.format("  draw (%f,%f) -- (%f,%f) withpen pencircle scaled %fpt%s withcolor %s;", x0, y1, x1, y0, ilw, idp, opts.iframe_stroke))
    end
end

local function draw_strokes(mp, data, step, opts, scale, offset_x)
    offset_x = offset_x or 0
    local total = data.count
    local show_step = step or total
    
    for i = 1, show_step do
        if i <= total then
            local stroke_mp = stroke_to_metafun(data.strokes[i], scale, offset_x)
            table.insert(mp, "  " .. stroke_mp)
            
            local is_last = (i >= show_step)
            local fill = is_last and opts.last_fill or opts.char_fill
            local stroke = is_last and opts.last_stroke or opts.char_stroke
            local lw = is_last and opts.last_linewidth or opts.char_linewidth
            local dp = dash_to_mp(is_last and opts.last_dashpattern or opts.char_dashpattern, lw)
            
            table.insert(mp, string.format("  fill p withcolor %s; draw p withpen pencircle scaled %fpt%s withcolor %s;", fill, lw, dp, stroke))
        end
    end
end

function bihua.generate_metafun(char, step)
    local opts = current_options
    local data = bihua.get_char(char)
    if not data then return "beginfig(0); endfig;" end
    
    local mp = {}
    local scale = opts.width / 1024
    
    table.insert(mp, "beginfig(0);")
    table.insert(mp, string.format("  w := %f; h := %f;", opts.width, opts.width))
    draw_frame(mp, opts)
    draw_strokes(mp, data, step, opts, scale)
    table.insert(mp, "endfig;")
    
    return table.concat(mp, "\n")
end

function bihua.generate_metafun_all(char)
    local opts = current_options
    local data = bihua.get_char(char)
    if not data then return "beginfig(0); endfig;" end
    
    local mp = {}
    local scale = opts.width / 1024
    local spacing = opts.spacing
    local total = data.count
    
    table.insert(mp, "beginfig(0);")
    
    for i = 1, total do
        local offset_x = (i - 1) * (opts.width + spacing)
        table.insert(mp, string.format("  %% 格子 %d", i))
        draw_frame(mp, opts, offset_x)
        draw_strokes(mp, data, i, opts, scale, offset_x)
    end
    
    table.insert(mp, "endfig;")
    return table.concat(mp, "\n")
end

local luafile = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
if luafile ~= "" then
    local luadir = file.dirname(luafile)
    if luadir ~= "" then bihua.set_data_dir(file.join(luadir, "data-bihua")) end
end
