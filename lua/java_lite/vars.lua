-- 空格 d 的一部分：光标下是局部变量 / 参数 / 字段 / 枚举常量时，找出它的声明位置。
-- 为什么不用 nvim 自带的 gd：它要先找“函数起点”（第 1 列的 {），Java 方法体是缩进的，找不到就从第 1 行开始搜，
-- 两个方法里有同名变量（result、x、i、e……）就会跳到别的方法里去。
-- 做法和 scan.lua 类似：不建语法树，单遍扫描，用花括号栈记下“每一层里声明了哪些名字”；
-- 到光标处从最里层往外找，第一个有这个名字的层就是答案——和 Java 的作用域规则一致。
-- 纯函数，不缓存任何东西。
local M = {}

-- 这些词后面跟着的 `名字` 不是声明（return x; throw e; class Foo ...）
local NOT_TYPE = {}
for w in ("return throw new else case break continue yield import package assert instanceof extends implements permits throws do goto class interface enum"):gmatch("%S+") do
    NOT_TYPE[w] = true
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

-- 把注释、字符串、字符字面量抹成空格（长度不变，列号才对得上）
-- state 跨行传递：nil | "block"（/* 还没结束）| "text"（""" 文本块还没结束）
local function clean(line, state)
    local out, pos, n = {}, 1, #line
    local function blank(a, b)
        out[#out + 1] = (" "):rep(b - a + 1)
    end
    while pos <= n do
        if state == "block" then
            local e = line:find("*/", pos, true)
            if not e then
                blank(pos, n)
                break
            end
            blank(pos, e + 1)
            pos, state = e + 2, nil
        elseif state == "text" then
            local e = line:find('"""', pos, true)
            if not e then
                blank(pos, n)
                break
            end
            blank(pos, e + 2)
            pos, state = e + 3, nil
        else
            local s = line:find("[/\"']", pos)
            if not s then
                out[#out + 1] = line:sub(pos)
                break
            end
            out[#out + 1] = line:sub(pos, s - 1)
            local two = line:sub(s, s + 1)
            if two == "/*" then
                blank(s, s + 1)
                state, pos = "block", s + 2
            elseif two == "//" then
                blank(s, n)
                break
            elseif line:byte(s) == 47 then
                out[#out + 1] = "/"
                pos = s + 1
            elseif line:sub(s, s + 2) == '"""' then
                blank(s, s + 2)
                state, pos = "text", s + 3
            else
                local e = skip_quoted(line, s, line:sub(s, s))
                blank(s, e - 1)
                pos = e
            end
        end
    end
    return table.concat(out), state
end

-- ---------------------------------------------------------------------------------------------
-- 在一小段文本里认声明：`Type name` 后面跟 = , : [] -> 或者语句 / 参数列表的结尾
-- ---------------------------------------------------------------------------------------------

-- a.b.C 这样带点的名字，返回最后一个字符的位置
local function ident_end(text, s)
    local _, e = text:find("^[%a_$][%w_$]*", s)
    while true do
        local _, e2 = text:find("^%.%s*[%a_$][%w_$]*", e + 1)
        if not e2 then
            return e
        end
        e = e2
    end
end

-- s 处是 "<"：返回配对的 ">" 之后的位置；里面出现类型里不会有的字符（比如 a < b && c > d 里的 &&）就返回 nil
local function skip_generics(text, s)
    local depth = 0
    for i = s, #text do
        local c = text:sub(i, i)
        if c == "<" then
            depth = depth + 1
        elseif c == ">" then
            depth = depth - 1
            if depth == 0 then
                return i + 1
            end
        elseif not c:find("[%w_$.,?%s%[%]]") and not (c == "&" and text:sub(i + 1, i + 1) ~= "&") then
            return nil
        end
    end
end

-- 从 s 处的类型名开始，返回类型结束之后的位置（含泛型 <...>、数组 [] 和可变参数 ...）；不像类型就返回 nil
local function type_end(text, s)
    local e = ident_end(text, s)
    if NOT_TYPE[text:sub(s, e)] then
        return nil
    end
    local i = e + 1
    while true do
        local j = text:find("%S", i)
        if not j then
            return i
        end
        local c = text:sub(j, j)
        if c == "<" then
            i = skip_generics(text, j)
            if not i then
                return nil
            end
        elseif c == "[" and text:find("^%[%s*%]", j) then
            i = select(2, text:find("^%[%s*%]", j)) + 1
        elseif text:find("^%.%.%.", j) then
            i = j + 3
        else
            return i
        end
    end
end

-- 名字后面跟什么，才说明它是被声明的；rest 是名字之后本段剩下的文本，delim 是本段后面紧跟的符号（行尾为 nil）
local function ends_decl(rest, delim)
    local r = rest:match("^%s*(.*)$")
    -- C 风格数组 int a[] = ...：先吃掉 []，再看后面
    local stripped = r:gsub("^%[%s*%]%s*", "")
    while stripped ~= r do
        r, stripped = stripped, stripped:gsub("^%[%s*%]%s*", "")
    end
    if r == "" then
        return delim == nil or delim == ";" or delim == ")"
    end
    local c, c2 = r:sub(1, 1), r:sub(1, 2)
    return (c == "=" and c2 ~= "==") or c == "," or (c == ":" and c2 ~= "::") or c2 == "->"
end

-- found(名字, 它在 text 里的位置, 种类)；种类：nil 普通声明 | "lambda" lambda 参数 | "inst" instanceof 模式变量
-- chain：这条语句前面已经声明过变量（int a = 1, b = 2; 里的 b）；lead_comma：上一行以逗号结尾（b 在下一行）
-- 返回这段结束后 chain 的值
local function find_decls(text, delim, chain, lead_comma, found)
    local pos = 1
    while true do
        local s = text:find("[%a_$]", pos)
        if not s then
            return chain
        end
        local e = ident_end(text, s)
        local word = text:sub(s, e)
        pos = e + 1
        if not (s > 1 and text:sub(s - 1, s - 1):find("[%w_$]")) then -- 数字字面量的一部分（0xFF、1e5）不算
            local hit = false
            local ti = type_end(text, s)
            local n1 = ti and text:find("%S", ti)
            if n1 and text:find("^[%a_$]", n1) then
                local _, ne = text:find("^[%a_$][%w_$]*", n1)
                local name = text:sub(n1, ne)
                if not NOT_TYPE[name] and ends_decl(text:sub(ne + 1), delim) then
                    found(name, n1)
                    chain, hit, pos = true, true, ne + 1
                end
            end
            if not hit then
                local plain = not word:find(".", 1, true)
                local before = text:sub(1, s - 1)
                if word == "instanceof" then -- o instanceof Foo f
                    local t0 = text:find("[%a_$]", e + 1)
                    local t1 = t0 and type_end(text, t0)
                    local n2 = t1 and text:match("^%s*()[%a_$]", t1)
                    local name = n2 and text:match("^[%a_$][%w_$]*", n2)
                    if name and not NOT_TYPE[name] then
                        found(name, n2, "inst")
                    end
                elseif plain and word ~= "default" and text:find("^%s*%->", e + 1) and not before:find("%f[%w_$]case%f[^%w_$]") then
                    found(word, s, "lambda") -- x -> ...（case X -> 是 switch 的标签，不是 lambda）
                elseif chain and plain and (before:find(",%s*$") or (lead_comma and not before:find("%S")))
                    and ends_decl(text:sub(e + 1), delim) then
                    found(word, s) -- int a = 1, b = 2; 里的 b
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- 作用域栈
-- ---------------------------------------------------------------------------------------------

-- kind：top（文件顶层）| class（类 / 接口 / 枚举 / 记录 / 匿名类的体）| block（方法体、代码块）
-- decls：名字 → { name, lnum, col }；paren 括号深度；pnew 每个未闭合的 ( 前面是不是 new X
-- stmt 当前这条语句在括号外的文本（判断 { 是不是类体）；chain 见 find_decls；consts 枚举体里还在写常量
-- insts：instanceof 的模式变量（名字 → 声明列表）。if (!(o instanceof Foo f)) return; 之后 f 仍然能用，
--   所以记在它所在的这一层里，同名的可以有好几个，查的时候取光标之前最近的
-- pend：括号里声明、还没找到归属的名字。{ d = 声明, lambda = 是不是 lambda 参数, depth = 声明时的括号深度 }
--   方法参数、for / catch / try 的头：属于后面括号闭合后紧跟的那个 {（深度 = 那个 { 所在深度 + 1）
--   lambda 参数：属于同一括号深度的 { ；表达式形式的 lambda 在它的括号闭合时失效
local function new_scope(kind)
    return { kind = kind, decls = {}, insts = {}, paren = 0, pnew = {}, stmt = "", chain = false, consts = false, pend = {} }
end

local function add_decl(top, name, lnum, col0, kind, depth)
    local d = { name = name, lnum = lnum, col = col0 }
    if kind == "inst" then
        top.insts[name] = top.insts[name] or {}
        table.insert(top.insts[name], d)
    elseif kind == "lambda" then
        top.pend[#top.pend + 1] = { d = d, lambda = true, depth = depth or top.paren }
    elseif top.paren > 0 then
        top.pend[#top.pend + 1] = { d = d, lambda = false, depth = top.paren }
    elseif not top.decls[name] then
        top.decls[name] = d
    end
end

-- 处理两个 { } ; ( ) 之间的一段文本；base 是它在行里的起始位置（1 基）
local function chunk(top, lnum, base, text, delim, lead_comma)
    if top.paren == 0 and #top.stmt < 4096 then
        top.stmt = top.stmt .. " " .. text
    end
    if top.consts then -- 枚举体里分号之前都是常量：RED, GREEN("g")
        if top.paren == 0 then
            for at, name in text:gmatch("()([%a_$][%w_$]*)") do
                if text:sub(at - 1, at - 1) ~= "@" and not top.decls[name] then
                    top.decls[name] = { name = name, lnum = lnum, col = base + at - 2 }
                end
            end
        end
        return
    end
    local active = top.chain ~= false and top.chain == top.paren -- chain 记的是上一个声明所在的括号深度
    local made = find_decls(text, delim, active, lead_comma, function(name, at, kind)
        add_decl(top, name, lnum, base + at - 2, kind)
    end)
    if made and not active then
        top.chain = top.paren
    end
end

local function snapshot(st)
    local chain, pends = vim.list_extend({}, st.stack), {}
    for k, sc in ipairs(chain) do
        pends[k] = vim.list_extend({}, sc.pend)
    end
    st.snap = { chain = chain, pends = pends }
end

-- 处理一行；cs 非空表示光标所在标识符在这一行、起点是 cs（1 基）：处理到它后面第一个 { } ; ( ) 之前存一份快照
local function feed_line(st, lnum, line, cs)
    local code
    code, st.cstate = clean(line, st.cstate)
    local lead_comma = st.prev_comma
    st.prev_comma = code:find(",%s*$") ~= nil
    local pos = 1
    while true do
        local s = code:find("[{};()]", pos)
        local top = st.stack[#st.stack]
        local text = code:sub(pos, (s or #code + 1) - 1)
        local c = s and code:sub(s, s) or nil
        if text:find("%S") then
            local n0 = #top.pend
            chunk(top, lnum, pos, text, c, lead_comma and pos == 1)
            if c == ")" and code:find("^%s*%->", s + 1) then
                -- (a, b) -> ...：括号里的都是 lambda 参数，归属 ) 之后同一深度的 {
                for k = n0 + 1, #top.pend do
                    top.pend[k].lambda, top.pend[k].depth = true, top.paren - 1
                end
                for at, piece in text:gmatch("()([^,]+)") do -- 没写类型的那种：名字单独一个
                    local name = piece:match("^%s*([%a_$][%w_$]*)%s*$")
                    if name then
                        add_decl(top, name, lnum, pos + at + piece:find("[%a_$]") - 3, "lambda", top.paren - 1)
                    end
                end
            end
        end
        if cs and not st.snap and (not s or s > cs) then
            snapshot(st)
        end
        if not s then
            return
        end
        pos = s + 1

        if c == "(" then
            top.pnew[#top.pnew + 1] = text:find("%f[%w_$]new%s+[%w_$.<>?,%s]*$") ~= nil
            top.paren = top.paren + 1
            top.last = c
        elseif c == ")" then
            top.paren = math.max(0, top.paren - 1)
            top.closed_new = table.remove(top.pnew)
            top.last = c
            local keep = {} -- 表达式形式的 lambda（x -> x + 1）的参数，括号一闭合就看不见了
            for _, e in ipairs(top.pend) do
                if not (e.lambda and e.depth > top.paren) then
                    keep[#keep + 1] = e
                end
            end
            top.pend = keep
            if top.chain and top.chain > top.paren then
                top.chain = false
            end
        elseif c == ";" then
            top.last = c
            if top.paren == 0 then
                top.stmt, top.chain, top.pend = "", false, {}
                top.consts = false
            elseif top.chain == top.paren then
                top.chain = false -- for (int i = 0, n = 5; ...) 里分号之后不再是声明
            end
        elseif c == "{" then
            local stmt, kind, is_enum = top.stmt, "block", false
            if top.consts then
                kind = "class" -- 枚举常量带的方法体
            elseif top.paren == 0 and (stmt:find("%f[%w_$]class%s+[%a_$]") or stmt:find("%f[%w_$]interface%s+[%a_$]") or stmt:find("%f[%w_$]enum%s+[%a_$]") or stmt:find("%f[%w_$]record%s+[%a_$]")) then
                kind, is_enum = "class", stmt:find("%f[%w_$]enum%s+[%a_$]") ~= nil
            elseif top.last == ")" and top.closed_new and not text:find("%S") then
                kind = "class" -- new Foo(...) { ... } 匿名类
            end
            local sc = new_scope(kind)
            sc.consts = is_enum
            local keep = {}
            for _, e in ipairs(top.pend) do
                if (e.lambda and e.depth == top.paren) or (not e.lambda and e.depth == top.paren + 1) then
                    sc.decls[e.d.name] = sc.decls[e.d.name] or e.d
                    if kind == "class" and top.paren > 0 then
                        keep[#keep + 1] = e -- 匿名类体里能看到外面的 lambda 参数，但外面还要继续用
                    end
                else
                    keep[#keep + 1] = e
                end
            end
            top.pend = keep
            if top.paren == 0 then
                top.stmt, top.chain = "", false
            end
            top.last = c
            if is_enum then
                st.enums[#st.enums + 1] = sc
            end
            st.stack[#st.stack + 1] = sc
        else -- "}"
            if #st.stack > 1 then
                table.remove(st.stack).closed = true
            end
            local parent = st.stack[#st.stack]
            parent.last = c
            if parent.paren == 0 then
                parent.stmt, parent.chain = "", false
            end
        end
    end
end

-- 找光标处名字的声明。lines 是整个缓冲区；(lnum, col) 是光标所在标识符的起点（1 基行、0 基列）；
-- fields_only：只找字段（this.x 的情形）。返回 { name, lnum, col }，找不到返回 nil
-- 找不到的情况：继承来的字段、别的类的成员、静态导入——这些在别的文件里，这里不管
function M.find(lines, lnum, col, name, fields_only)
    local st = { stack = { new_scope("top") }, enums = {} }
    local i = 0
    local function feed()
        i = i + 1
        feed_line(st, i, lines[i], i == lnum and col + 1 or nil)
    end
    while i < lnum do
        feed()
    end
    if not st.snap then
        snapshot(st)
    end

    -- 局部变量只在声明之后才看得见；字段在类里任何位置声明都算
    local function seen(d)
        return d.lnum < lnum or (d.lnum == lnum and d.col <= col)
    end
    local chain, pends = st.snap.chain, st.snap.pends
    for k = #chain, 1, -1 do
        local sc, d = chain[k], nil
        if not fields_only then
            for j = #pends[k], 1, -1 do
                local e = pends[k][j]
                if e.d.name == name and seen(e.d) then
                    return e.d
                end
            end
        end
        local insts = not fields_only and sc.kind ~= "class" and sc.insts[name]
        for j = insts and #insts or 0, 1, -1 do -- instanceof 的模式变量：取光标之前最近的那个
            if seen(insts[j]) then
                return insts[j]
            end
        end
        if sc.kind == "class" then
            while i < #lines and not sc.closed do -- 把这个类继续扫到结束，后面才声明的字段也要算
                feed()
            end
            d = sc.decls[name]
        elseif not fields_only then
            d = sc.decls[name]
            if d and not seen(d) then
                d = nil
            end
        end
        if d then
            return d
        end
    end

    -- switch 的 case 标签可以直接写枚举常量（case RED:），这不走作用域规则，要靠 switch 的类型：
    -- 本文件里有枚举声明了这个常量，就算它
    local before = lines[lnum]:sub(1, col)
    if not fields_only and before:find("%f[%w_$]case%f[^%w_$]") then
        while i < #lines do
            feed()
        end
        for _, sc in ipairs(st.enums) do
            if sc.decls[name] then
                return sc.decls[name]
            end
        end
    end
end

return M
