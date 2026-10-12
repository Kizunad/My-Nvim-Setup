-- 不依赖任何解析器的 Java 声明扫描器，只认类和方法。
-- 做法：单遍扫描，先抹掉注释/字符串，再用花括号栈区分“类体”和“方法体/代码块”。
-- 只有在类体这一层，`名字(` 才会被当成方法声明，方法体里的调用 foo(x) 不会误报。
-- 纯函数：传入行列表，返回符号列表，不缓存任何东西。
local M = {}

local TYPE_KW = { "class", "interface", "enum", "record" }
local NOT_METHOD = { ["if"] = true, ["for"] = true, ["while"] = true, ["switch"] = true, ["catch"] = true, ["synchronized"] = true }

local function blank(m)
    return (" "):rep(#m)
end

-- 返回结束引号之后的位置；s 是起始引号的位置，q 是引号字符
local function skip_quoted(line, s, q)
    local pos = s + 1
    while true do
        local i = line:find("[\\" .. q .. "]", pos)
        if not i then
            return #line + 1
        end
        if line:byte(i) == 92 then
            pos = i + 2
        else
            return i + 1
        end
    end
end

-- 抹掉一行里的注释、字符串、字符字面量，只留下会影响 { } ; ( ) 判断的代码
-- state：nil | "block"（/* 还没结束）| "text"（""" 文本块还没结束），跨行传递
local function clean(line, state)
    local out, pos = {}, 1
    while pos <= #line do
        if state == "block" then
            local e = line:find("*/", pos, true)
            if not e then
                break
            end
            pos, state = e + 2, nil
        elseif state == "text" then
            local e = line:find('"""', pos, true)
            if not e then
                break
            end
            pos, state = e + 3, nil
            out[#out + 1] = '""'
        else
            local s = line:find("[/\"']", pos)
            if not s then
                out[#out + 1] = line:sub(pos)
                break
            end
            out[#out + 1] = line:sub(pos, s - 1)
            local two = line:sub(s, s + 1)
            if two == "/*" then
                state, pos = "block", s + 2
            elseif two == "//" then
                break
            elseif line:byte(s) == 47 then
                out[#out + 1] = "/"
                pos = s + 1
            elseif line:sub(s, s + 2) == '"""' then
                state, pos = "text", s + 3
            elseif line:byte(s) == 34 then
                out[#out + 1] = '""'
                pos = skip_quoted(line, s, '"')
            else
                out[#out + 1] = "''"
                pos = skip_quoted(line, s, "'")
            end
        end
    end
    return table.concat(out), state
end

-- 栈里的一层：kind = top（文件顶层）| type（类体）| enum（枚举体）| block（方法体等）
-- 当前这条语句的文本存成分段缓冲 parts（总长 len），需要判断时才拼成字符串；
-- marks 记录每段文本从第几个字符开始、在第几行。parts/marks 用到才创建，省分配
local function new_level(kind, name, is_record)
    return { kind = kind, name = name, is_record = is_record, len = 0, paren = 0, consts = kind == "enum" }
end

local function reset(level)
    if level.len > 0 then
        level.parts, level.marks, level.mark_line, level.len = nil, nil, nil, 0
    end
end

-- 一条语句的文本超过这个长度就不再累积：那只会是大数组初始化、巨型枚举常量表之类，不可能是声明。
-- 不设上限，反复 .. 拼接越来越长的字符串是 O(n²)：1 万行的文件一次扫描能产生上百 MB 垃圾
local MAX_STMT = 4096

local function put(level, text, lnum)
    if level.len >= MAX_STMT then
        return
    end
    if not level.parts then
        level.parts, level.marks = {}, {}
    end
    if level.mark_line ~= lnum then
        -- 换行处补一个空格，否则 `public final` + `class Void` 会粘成 `finalclass`
        if level.len > 0 then
            level.parts[#level.parts + 1] = " "
            level.len = level.len + 1
        end
        level.marks[#level.marks + 1] = { level.len + 1, lnum }
        level.mark_line = lnum
    end
    level.parts[#level.parts + 1] = text
    level.len = level.len + #text
end

local function stmt_of(level)
    return level.parts and table.concat(level.parts) or ""
end

local function line_at(level, off)
    local line
    for _, m in ipairs(level.marks or {}) do
        if m[1] > off then
            break
        end
        line = m[2]
    end
    return line
end

-- 判断一条语句是类声明还是方法声明；off 是名字关键位置在 stmt 里的偏移
-- allow_method 为 false 时（不在类体里）只认类；record_name 非空时，还认 record 的紧凑构造器 `Name {`
local function classify(stmt, allow_method, record_name)
    local s, _, name = stmt:find("@%s*interface%s+([%w_$]+)")
    if s then
        return "annotation", name, s
    end
    -- 注解（含参数）换成等长空格，既不干扰后面的判断，又保持偏移不变
    local masked = stmt:gsub("@[%w_.$]+%s*%b()", blank):gsub("@[%w_.$]+", blank)
    for _, kw in ipairs(TYPE_KW) do
        local pat = kw == "record" and ("%f[%w_$]record%s+([%w_$]+)%s*[(<]") or ("%f[%w_$]" .. kw .. "%s+([%w_$]+)")
        local s2, _, n = masked:find(pat)
        if s2 and masked:sub(s2 - 1, s2 - 1) ~= "." then
            return kw, n, s2
        end
    end
    if allow_method then
        local s3, _, nm = masked:find("([%a_$][%w_$]*)%s*%(")
        -- = 在 ( 之前说明是字段初始化 int x = foo(1);，不是方法
        if s3 and not NOT_METHOD[nm] and not masked:sub(1, s3 - 1):find("=") then
            return "method", nm, s3
        end
        if record_name then
            local s4 = masked:find("%f[%w_$]" .. record_name:gsub("%p", "%%%0") .. "%s*$")
            if s4 then
                return "method", record_name, s4
            end
        end
    end
end

-- 语句末尾是 new Foo(...) ，后面紧跟 { —— 匿名类
local function is_anonymous(stmt)
    return stmt:find("new", 1, true) and stmt:find("%f[%w_$]new%s+[%w_.$<>,?%[%]%s]*%b()%s*$") ~= nil
end

-- 返回 { { lnum, col, kind, name, owner, depth, text }, ... }，按行号升序
--   kind  : method | class | interface | enum | record | annotation（构造方法也算 method）
--   col   : 名字在行内的 0 基列号
--   owner : 外层类名，如 "Outer.Inner"（匿名类不计入）
function M.symbols(lines)
    local syms, stack, state = {}, { new_level("top") }, nil

    local function add(level, kind, name, off, fallback_line)
        local lnum = line_at(level, off) or fallback_line
        local owner, depth = {}, 0
        for k = 2, #stack do
            if stack[k].name then
                owner[#owner + 1] = stack[k].name
                depth = depth + 1
            end
        end
        local src = lines[lnum] or ""
        local col = (src:find("%f[%w_$]" .. name:gsub("%p", "%%%0") .. "%f[^%w_$]") or 1) - 1
        syms[#syms + 1] = {
            lnum = lnum,
            col = col,
            kind = kind,
            name = name,
            owner = table.concat(owner, "."),
            depth = depth,
            text = (src:match("^%s*(.-)%s*$"):gsub("%s*{%s*$", "")),
        }
    end

    for i = 1, #lines do
        local code
        code, state = clean(lines[i], state)
        local pos = 1
        while true do
            local s = code:find("[{};()]", pos)
            local top = stack[#stack]
            local seg = code:sub(pos, (s or #code + 1) - 1)
            if seg:find("%S") then
                put(top, seg, i)
            end
            if not s then
                break
            end
            local c = code:sub(s, s)
            pos = s + 1

            if c == "(" then
                top.paren = top.paren + 1
                put(top, c, i)
            elseif c == ")" then
                top.paren = math.max(0, top.paren - 1)
                put(top, c, i)
            elseif c == ";" then
                if top.paren > 0 then
                    put(top, c, i) -- for (;;) 之类
                else
                    -- 接口里的抽象方法：void foo(int x);
                    if top.kind == "type" or (top.kind == "enum" and not top.consts) then
                        local kind, name, off = classify(stmt_of(top), true)
                        if kind == "method" then
                            add(top, kind, name, off, i)
                        end
                    end
                    if top.kind == "enum" then
                        top.consts = false -- 枚举常量部分到 ; 结束
                    end
                    reset(top)
                end
            elseif c == "{" then
                local in_parens = top.paren > 0
                local can_method = top.kind == "type" or (top.kind == "enum" and not top.consts)
                local kind, name, off
                local stmt = stmt_of(top)
                -- 方法体里绝大多数 { 都是 if/for/try，先用便宜的纯文本查找排除掉
                local maybe_decl = top.kind ~= "block"
                    or stmt:find("class", 1, true)
                    or stmt:find("interface", 1, true)
                    or stmt:find("enum", 1, true)
                    or stmt:find("record", 1, true)
                if not in_parens and maybe_decl then
                    kind, name, off = classify(stmt, can_method, top.is_record and top.name or nil)
                end

                if kind == "method" then
                    add(top, kind, name, off, i)
                    stack[#stack + 1] = new_level("block")
                elseif kind then
                    add(top, kind, name, off, i)
                    stack[#stack + 1] = new_level(kind == "enum" and "enum" or "type", name, kind == "record")
                elseif (top.kind == "enum" and top.consts) or is_anonymous(stmt) then
                    stack[#stack + 1] = new_level("type") -- 枚举常量体 / 匿名类：里面的方法也要认
                else
                    stack[#stack + 1] = new_level("block")
                end
                if not in_parens then
                    reset(top)
                end
            else -- "}"
                if #stack > 1 then
                    stack[#stack] = nil
                end
                local parent = stack[#stack]
                if parent.paren == 0 then
                    reset(parent)
                end
            end
        end
    end
    return syms
end

return M
