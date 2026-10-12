-- 空格 d：悬浮窗里看光标下（或选中的）类 / 方法的定义，浮窗里按 b 打开在线文档
-- 找源码的顺序：当前项目 → JDK 自带的 src.zip → Gradle 缓存里的 *-sources.jar（目前只认 Gradle 缓存）。
-- 找到源码就在悬浮窗里显示（从 Javadoc 注释开始）；只有 jar 没有源码，就打开 javadoc.io；
-- 本地什么都没有，就在浏览器里搜索。每次按键现查现用，rg / unzip 跑完即退出，不建索引、不缓存。
local scan = require("java_lite.scan")

local M = {}

local function notify(msg, level)
    vim.notify("java_lite: " .. msg, level or vim.log.levels.INFO)
end

-- 跑一个命令，返回 stdout；命令不存在 / 超时都当作没输出（rg 没匹配时退出码是 1，所以不看退出码）
local function run(cmd, timeout)
    local ok, res = pcall(function()
        return vim.system(cmd, { text = true }):wait(timeout or 5000)
    end)
    return ok and res.stdout or ""
end

local function run_lines(cmd, timeout)
    return vim.split(run(cmd, timeout), "\n", { trimempty = true })
end

local function zip_entry(zip, entry)
    local lines = vim.split(run({ "unzip", "-p", zip, entry }, 10000), "\n", { plain = true })
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    for i, l in ipairs(lines) do
        lines[i] = (l:gsub("\r$", ""))
    end
    return lines
end

-- ---------------------------------------------------------------------------------------------
-- 光标下是什么：返回 "a.b.C.d" 拆成的段，只到光标所在那一段为止（后面的部分和光标处的符号无关）
-- ---------------------------------------------------------------------------------------------

local function split_chain(text)
    local segs = {}
    for seg in text:gmatch("[^.]+") do
        segs[#segs + 1] = seg
    end
    return segs
end

local function target_at_cursor()
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
        local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
        vim.cmd("normal! \27") -- 退出可视模式
        local text = vim.trim(table.concat(region, " "))
        if text:find("^[%w_$.]+$") then
            return split_chain(text)
        end
        return nil, "选中的内容不是类名或方法名"
    end
    local line, col = vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2] + 1
    if not line:sub(col, col):find("[%w_$]") then
        return nil, "光标下没有标识符"
    end
    local s, e = col, col
    while s > 1 and line:sub(s - 1, s - 1):find("[%w_$.]") do
        s = s - 1
    end
    while line:sub(e + 1, e + 1):find("[%w_$]") do
        e = e + 1
    end
    return split_chain(line:sub(s, e))
end

-- ---------------------------------------------------------------------------------------------
-- 把名字解析成候选的 { pkg, cls, target }：pkg 包名，cls 顶层类名，target 要在类里找的方法 / 嵌套类
-- ---------------------------------------------------------------------------------------------

local function is_upper(s)
    return s:find("^%u") ~= nil
end

-- "a.b.Outer.Inner" → { pkg = "a.b", cls = "Outer", target = "Inner" }；没有大写开头的段就返回 nil
local function split_fqcn(path)
    local segs = split_chain(path)
    for k, s in ipairs(segs) do
        if is_upper(s) then
            return {
                pkg = k > 1 and table.concat(segs, ".", 1, k - 1) or nil,
                cls = s,
                target = k < #segs and segs[#segs] or nil,
            }
        end
    end
end

local function parse_imports(lines)
    local imp = { exact = {}, wild = {}, static = {}, static_wild = {} }
    for _, l in ipairs(lines) do
        local v = l:match("^%s*package%s+([%w_.]+)%s*;")
        if v then
            imp.pkg = v
        else
            v = l:match("^%s*import%s+static%s+([%w_.]+)%.%*%s*;")
            if v then
                imp.static_wild[#imp.static_wild + 1] = v
            else
                v = l:match("^%s*import%s+static%s+([%w_.]+)%s*;")
                if v then
                    imp.static[v:match("([^.]+)$")] = v
                else
                    v = l:match("^%s*import%s+([%w_.]+)%.%*%s*;")
                    if v then
                        imp.wild[#imp.wild + 1] = v
                    else
                        v = l:match("^%s*import%s+([%w_.]+)%s*;")
                        if v then
                            imp.exact[v:match("([^.]+)$")] = v
                        end
                    end
                end
            end
        end
    end
    return imp
end

local function resolve(segs, imp)
    local ci
    for k, s in ipairs(segs) do
        if is_upper(s) then
            ci = k
            break
        end
    end
    local hint = "把光标放在类名上（如 JsonParser），或选中类名再按 空格 d"

    if not ci then
        -- 没有大写开头的段：可能是静态导入的方法，如 parseReader(...)
        if #segs == 1 then
            local name, list = segs[1], {}
            local full = imp.static[name]
            local c = full and split_fqcn(full)
            if c then
                c.target = name
                return { c }
            end
            for _, w in ipairs(imp.static_wild) do -- import static a.B.*：名字不一定在这个类里
                c = split_fqcn(w)
                if c then
                    c.target, c.speculative = name, true
                    list[#list + 1] = c
                end
            end
            if #list > 0 then
                return list
            end
        end
        if #segs == 1 then
            return nil, "本文件里没找到 " .. segs[1] .. " 的声明（继承来的字段、别的类的成员我不查）；要看某个类，" .. hint
        end
        return nil, "看不出 " .. segs[#segs] .. " 属于哪个类（链式调用里的类型我不推断），" .. hint
    end
    if #segs > ci + 1 then
        return nil, "看不出 " .. segs[#segs] .. " 的类型（链式调用），" .. hint
    end

    local name, member, list = segs[ci], segs[ci + 1], {}
    -- speculative：靠猜出来的候选（import a.B.* 里的嵌套类），类存在还不够，里面得真有这个成员才算数
    local function add(pkg, cls, target, speculative)
        list[#list + 1] = { pkg = pkg, cls = cls, target = target or member, speculative = speculative }
    end
    -- explicit：包名是代码里明确写出来的（全限定名 / 精确 import），本地找不到时拿它去搜索才不会误导
    if ci > 1 then
        add(table.concat(segs, ".", 1, ci - 1), name) -- 写全了包名：com.google.gson.JsonParser
        list[#list].explicit = true
    elseif imp.exact[name] then
        local c = split_fqcn(imp.exact[name]) -- 类名是小写开头的怪情况时为 nil
        if c then
            add(c.pkg, c.cls, member or c.target)
            list[#list].explicit = true
        else
            add(nil, name)
        end
    else
        -- 不在 import 里：同包 → java.lang → import xxx.*，最后在项目里按类名碰碰运气
        if imp.pkg then
            add(imp.pkg, name)
        end
        add("java.lang", name)
        for _, w in ipairs(imp.wild) do
            local c = split_fqcn(w) -- import a.b.Outer.* 导入的是 Outer 里的嵌套类
            if c then
                add(c.pkg, c.cls, member or name, true)
            else
                add(w, name)
            end
        end
        add(nil, name)
    end
    return list
end

-- ---------------------------------------------------------------------------------------------
-- 找源码 / jar
-- ---------------------------------------------------------------------------------------------

local function rel_of(cand)
    return (cand.pkg and (cand.pkg:gsub("%.", "/")) .. "/" or "") .. cand.cls
end

local function jdk_src_zip()
    local homes = {}
    if vim.env.JAVA_HOME and vim.env.JAVA_HOME ~= "" then
        homes[#homes + 1] = vim.env.JAVA_HOME
    end
    local javac = vim.fn.exepath("javac")
    local real = javac ~= "" and vim.uv.fs_realpath(javac)
    if real then
        homes[#homes + 1] = vim.fs.dirname(vim.fs.dirname(real))
    end
    for _, h in ipairs(homes) do
        for _, rel in ipairs({ "/lib/src.zip", "/src.zip" }) do
            if vim.uv.fs_stat(h .. rel) then
                return h .. rel, h
            end
        end
    end
end

local function jdk_major(home)
    local f = io.open(home .. "/release")
    local text = f and f:read("*a") or ""
    if f then
        f:close()
    end
    local v = text:match('JAVA_VERSION="([^"]+)"') or ""
    return v:match("^1%.(%d+)") or v:match("^(%d+)") or "21"
end

local function gradle_cache()
    local home = vim.env.GRADLE_USER_HOME
    home = (home and home ~= "") and home or (vim.uv.os_homedir() .. "/.gradle")
    local dir = home .. "/caches/modules-2/files-2.1" -- <group>/<artifact>/<version>/<hash>/<file>
    return vim.uv.fs_stat(dir) and dir or nil
end

local function newer(a, b) -- 版本号 a 比 b 新吗（按数字段比较：2.10.1 > 2.10 > 2.8.9）
    local pa, pb = {}, {}
    for n in a:gmatch("%d+") do
        pa[#pa + 1] = tonumber(n)
    end
    for n in b:gmatch("%d+") do
        pb[#pb + 1] = tonumber(n)
    end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then
            return x > y
        end
    end
    return a > b
end

-- 从 rg 列出的缓存路径里挑版本最新的，并从路径还原 group / artifact / version
local function best_by_version(paths, cache)
    local best
    for _, p in ipairs(paths) do
        local g, a, v = p:sub(#cache + 2):match("^([^/]+)/([^/]+)/([^/]+)/")
        if g and (not best or newer(v, best.v)) then
            best = { path = p, g = g, a = a, v = v }
        end
    end
    return best
end

local function locate(cand, root)
    local rel = rel_of(cand)

    local hits = run_lines({ "rg", "--files", "-g", "**/" .. rel .. ".java", root })
    if #hits > 0 then
        table.sort(hits)
        return { kind = "project", file = hits[1], label = vim.fn.fnamemodify(hits[1], ":~:.") }
    end
    if not cand.pkg then
        return nil -- 没有包名时，只在项目里按类名找；jar / JDK 里不碰运气
    end

    local zip, home = jdk_src_zip()
    if zip then
        -- JDK 9+ 的 src.zip 条目带模块名前缀（java.base/java/util/List.java），JDK 8 的没有
        local entry = run_lines({ "unzip", "-Z1", zip, rel .. ".java", "*/" .. rel .. ".java" })[1]
        if entry then
            local module = #entry > #rel + 5 and entry:sub(1, #entry - #rel - 6) or nil
            return { kind = "jdk", zip = zip, home = home, entry = entry, module = module, label = "JDK src.zip" .. (module and (" · " .. module) or "") }
        end
    end

    local cache = gradle_cache()
    if cache then
        local base = { "rg", "-l", "-a", "-F", "--no-ignore" }
        local function search(glob, needle)
            local cmd = vim.list_extend(vim.list_extend({}, base), { "--glob", glob, "-e", needle, cache })
            return best_by_version(run_lines(cmd), cache)
        end
        local src = search("*-sources.jar", rel .. ".java")
        if src then
            src.kind, src.entry, src.label = "jar-src", rel .. ".java", string.format("%s:%s:%s 源码", src.g, src.a, src.v)
            src.cache = cache
            return src
        end
        local jar = search("*.jar", rel .. ".class")
        if jar then
            jar.kind, jar.label, jar.cache = "jar", string.format("%s:%s:%s（只有 jar，没有源码）", jar.g, jar.a, jar.v), cache
            return jar
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- 在线文档地址 + 用 Windows 默认浏览器打开
-- ---------------------------------------------------------------------------------------------

-- javadoc.io 上模块化的库（有 module-info）页面在 <模块名>/ 下面，不带模块名会被重定向回首页；
-- 非模块化的库则不能带。jar 里没有 module-info.class 就是非模块化（秒判）；
-- 有的话用 JDK 自带的 jar 命令读出模块名（只在要打开浏览器时跑，约 0.3 秒）
local function module_name(loc)
    local jars = vim.fn.glob(string.format("%s/%s/%s/%s/*/*.jar", loc.cache, loc.g, loc.a, loc.v), false, true)
    for _, j in ipairs(jars) do
        if not j:find("%-sources%.jar$") and not j:find("%-javadoc%.jar$") then
            if #run_lines({ "unzip", "-Z1", j, "*module-info.class" }) == 0 then
                return nil
            end
            local out = run({ "jar", "--describe-module", "--file", j }, 8000)
            -- 多版本 jar（模块描述符在 META-INF/versions/9/ 里）要带上 --release 才读得到
            local release = out:match("specify %-%-release") and out:match("releases:%s*(%d+)")
            if release then
                out = run({ "jar", "--describe-module", "--file", j, "--release", release }, 8000)
            end
            for line in out:gmatch("[^\n]+") do
                if not line:find("^releases:") then
                    return (not line:find("automatic", 1, true)) and line:match("^([%w_.]+)[@ ]") or nil
                end
            end
            return nil
        end
    end
end

local function url_of(loc, cand)
    local page = rel_of(cand)
    if cand.target and cand.target:find("^%u[%w_$]*%l") then
        page = page .. "." .. cand.target -- 嵌套类的页面是 Outer.Inner.html
    end
    page = page .. ".html"
    if loc.kind == "jdk" then
        if not loc.module then
            return "https://docs.oracle.com/javase/8/docs/api/" .. page
        end
        return string.format("https://docs.oracle.com/en/java/javase/%s/docs/api/%s/%s", jdk_major(loc.home), loc.module, page)
    elseif loc.kind == "jar-src" or loc.kind == "jar" then
        local mod = module_name(loc)
        return string.format("https://javadoc.io/doc/%s/%s/%s/%s%s", loc.g, loc.a, loc.v, mod and (mod .. "/") or "", page)
    end
end

local function fqcn_of(cand)
    return (cand.pkg and (cand.pkg .. ".") or "") .. cand.cls
end

function M.open_url(url, what)
    local cmd
    for _, exe in ipairs({ "wslview", "explorer.exe", "xdg-open" }) do -- WSL：explorer.exe 会交给 Windows 默认浏览器
        if vim.fn.executable(exe) == 1 then
            cmd = { exe, url }
            break
        end
    end
    if not cmd then
        return notify("找不到打开浏览器的命令（wslview / explorer.exe / xdg-open）", vim.log.levels.WARN)
    end
    vim.system(cmd, { detach = true }) -- explorer.exe 即使成功退出码也是 1，不看
    notify("已在浏览器里打开 " .. (what or url))
end

local function browse(loc, cand)
    local url = loc and url_of(loc, cand)
    if loc and not url then
        return notify(fqcn_of(cand) .. " 在项目里，没有在线文档；请在悬浮窗里查看源码")
    end
    if not url then
        local q = vim.uri_encode(fqcn_of(cand) .. " java")
        return M.open_url("https://www.google.com/search?q=" .. q, "对 " .. fqcn_of(cand) .. " 的搜索")
    end
    M.open_url(url, string.format("%s 的文档（%s）", fqcn_of(cand), url:match("//([^/]+)")))
end

-- ---------------------------------------------------------------------------------------------
-- 悬浮窗
-- ---------------------------------------------------------------------------------------------

local TYPE_KINDS = { class = true, interface = true, enum = true, record = true, annotation = true }

-- 扫描器不报字段和枚举常量，按声明的样子找：`@Native public static final int MAX_VALUE = ...;`、`FOO(1),`、`int count;`
-- 前面要有类型（不能是 return / throw 这类语句），注释行不算
local STATEMENT_KW = { ["return"] = true, throw = true, ["break"] = true, continue = true, yield = true, case = true, ["else"] = true }

local function find_field(lines, name)
    name = name:gsub("%p", "%%%0")
    local function declared(l, tail)
        if l:find("^%s*[*/]") then
            return false
        end
        local pre = l:match("^(%s*[^=;(){}]-)%f[%w_$]" .. name .. tail)
        local first = pre and pre:match("^%s*([%w_$@]+)")
        return first ~= nil and not STATEMENT_KW[first]
    end
    for i, l in ipairs(lines) do -- 带初始值的字段
        if declared(l, "%s*=[^=]") then
            return i
        end
    end
    for i, l in ipairs(lines) do -- 枚举常量
        if l:find("^%s*" .. name .. "%s*[,;(]") then
            return i
        end
    end
    for i, l in ipairs(lines) do -- 没有初始值的字段
        if declared(l, "%s*;") then
            return i
        end
    end
end

-- 在源码里找到要看的那一行：cand.target 非空就找它（方法 / 嵌套类 / 字段），否则找类本身
local function find_decl(lines, cand)
    local syms = scan.symbols(lines)
    local cls_sym, hit, count = nil, nil, 0
    local prefix = cand.cls:gsub("%p", "%%%0")
    for _, s in ipairs(syms) do
        if TYPE_KINDS[s.kind] and s.name == cand.cls and s.owner == "" then
            cls_sym = cls_sym or s
        end
        if cand.target and s.name == cand.target and (s.owner == cand.cls or s.owner:find("^" .. prefix .. "%.")) then
            count = count + 1
            hit = hit or s
        end
    end
    if cand.target and not hit then
        local i = find_field(lines, cand.target)
        if i then
            return { lnum = i, name = cand.target }, 1
        end
        return cls_sym, 0
    end
    return hit or cls_sym, count
end

-- 往上跳过紧贴着声明的注解和 Javadoc / 注释，让悬浮窗从注释开始显示
local function comment_start(lines, decl)
    local i = decl - 1
    while i >= 1 do
        local t = vim.trim(lines[i])
        if t == "" then
            -- 有的 Javadoc 和声明之间隔着空行（JDK 的 List.java 就是）：空行上面紧接着是注释结尾才继续
            local j = i - 1
            while j >= 1 and vim.trim(lines[j]) == "" do
                j = j - 1
            end
            if j >= 1 and vim.trim(lines[j]):find("%*/$") then
                i = j
            else
                break
            end
        elseif t:find("^@") or t:find("^//") then
            i = i - 1
        elseif t:find("%*/$") then
            while i >= 1 and not lines[i]:find("/%*") do
                i = i - 1
            end
            return math.max(i, 1)
        else
            break
        end
    end
    return i + 1
end

local function open_float(loc, cand, root, lines, decl, count)
    local start = comment_start(lines, decl.lnum)
    local what = cand.target and (cand.cls .. "." .. cand.target) or cand.cls
    local title = string.format(" %s  ·  %s%s ", what, loc.label, count > 1 and string.format("  ·  %d 个重载，显示第 1 个", count) or "")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local width = math.max(20, math.min(120, vim.o.columns - 8))
    local height = math.max(5, math.min(#lines - start + 1, math.floor(vim.o.lines * 0.7)))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        style = "minimal",
        border = "rounded",
        title = title,
        title_pos = "center",
        footer = " q 关闭 · b 浏览器打开文档 · 空格 d 看光标下的类型 ",
        footer_pos = "center",
    })
    vim.bo[buf].filetype = "java" -- 窗口开好之后再设，语法高亮才会加载
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.b[buf].java_doc_root = root -- 在悬浮窗里继续按空格 d 时，仍然在原来的项目里找
    vim.wo[win].number = true
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.api.nvim_win_set_cursor(win, { decl.lnum, 0 })
    -- 注释 + 声明放得下就从注释开头显示；Javadoc 太长放不下，就让声明出现在窗口上三分之一处（往上滚还能看到注释）
    local top = decl.lnum - start < height - 1 and start or math.max(start, decl.lnum - math.floor(height / 3))
    vim.fn.winrestview({ topline = top })

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true })
    end
    vim.keymap.set("n", "b", function()
        browse(loc, cand)
    end, { buffer = buf, nowait = true, silent = true, desc = "浏览器打开文档" })
    vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close }) -- 点窗口外面就关
end

-- 光标下是局部变量 / 参数 / 字段 / 枚举常量：直接跳到它的声明（怎么找见 vars.lua），返回 true 表示已处理
-- 方法调用（后面跟 "("）和 a.b 里的 b（别的对象的成员，不推断类型）不归这里管，交给后面按类名 / 方法名的流程
local function goto_variable(lines)
    local line, cur = vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)
    local s = cur[2] + 1
    if not line:sub(s, s):find("[%w_$]") then
        return false
    end
    local e = s
    while s > 1 and line:sub(s - 1, s - 1):find("[%w_$]") do
        s = s - 1
    end
    while line:sub(e + 1, e + 1):find("[%w_$]") do
        e = e + 1
    end
    local name, before = line:sub(s, e), line:sub(1, s - 1)
    local member = before:find("%.%s*$") ~= nil
    if line:sub(e + 1):find("^%s*%(") or (member and not before:find("%f[%w_$]this%s*%.%s*$")) then
        return false
    end
    local ok, d = pcall(require("java_lite.vars").find, lines, cur[1], s - 1, name, member) -- this.x 只找字段
    if not ok or not d then
        return false
    end
    if d.lnum == cur[1] and d.col == s - 1 then
        notify(name .. " 的声明就在这里")
        return true
    end
    local buf = vim.api.nvim_get_current_buf()
    local on_screen = d.lnum >= vim.fn.line("w0") and d.lnum <= vim.fn.line("w$")
    vim.cmd("normal! m'") -- 记进跳转列表，Ctrl-O / Alt+← 能回来
    vim.api.nvim_win_set_cursor(0, { d.lnum, d.col })
    vim.cmd(on_screen and "normal! zv" or "normal! zvzz")
    -- 名字闪一下，一眼看出落在哪
    local ns = vim.api.nvim_create_namespace("java_lite_flash")
    local mark = vim.api.nvim_buf_set_extmark(buf, ns, d.lnum - 1, d.col, { end_col = d.col + #name, hl_group = "IncSearch" })
    vim.defer_fn(function()
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
    end, 500)
    return true
end

function M.show()
    local segs, err = target_at_cursor()
    if not segs or #segs == 0 then
        return notify(err or "光标下没有标识符")
    end
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if goto_variable(lines) then
        return
    end
    local cands, why = resolve(segs, parse_imports(lines))
    if not cands then
        return notify(why)
    end

    local root = vim.b[buf].java_doc_root or require("java_lite.nav").project_root(buf)
    local function source_lines(l)
        if not l.lines then
            l.lines = l.kind == "project" and vim.fn.readfile(l.file) or zip_entry(l.zip or l.path, l.entry)
        end
        return l.lines
    end
    local loc, cand, rejected
    for _, c in ipairs(cands) do
        local l = locate(c, root)
        if l and c.speculative and l.kind ~= "jar" then
            local _, n = find_decl(source_lines(l), c)
            if n == 0 then
                rejected, l = c, nil
            end
        end
        if l then
            loc, cand = l, c
            break
        end
    end
    -- 候选全是猜的（import static a.B.* 之类），类都在、但里面没有这个成员：直说，别去搜索
    if not loc and rejected and #vim.tbl_filter(function(c)
        return not c.speculative
    end, cands) == 0 then
        return notify(string.format("导入的类里都没有 %s（已查 %s）", rejected.target, table.concat(vim.tbl_map(fqcn_of, cands), "、")))
    end
    if not loc then
        -- 包名是猜出来的（没写、也没 import）就只搜类名
        local guess = cands[1].explicit and cands[1] or { cls = cands[1].cls }
        notify("本地没找到 " .. fqcn_of(guess) .. " 的源码或 jar（JDK / 项目 / Gradle 缓存）")
        return browse(nil, guess)
    end

    if loc.kind == "jar" then
        notify(fqcn_of(cand) .. " 只有 jar、没有源码，改为打开在线文档")
        return browse(loc, cand)
    end

    local lines = source_lines(loc)
    local decl, count = find_decl(lines, cand)
    if not decl then
        decl, count = { lnum = 1 }, 0
        notify("没在源码里定位到 " .. (cand.target or cand.cls) .. "，显示文件开头")
    elseif cand.target and count == 0 then
        notify(cand.cls .. " 里没找到 " .. cand.target .. "，显示类的开头")
    end
    open_float(loc, cand, root, lines, decl, count)
end

return M
