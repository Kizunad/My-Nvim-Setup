-- :Diff：浮窗里看 git 还没提交的改动（相对 HEAD：已暂存 + 未暂存 + 新建的文件）
-- 显示的是文件的完整内容，删掉的行（红）和新增的行（绿）夹在原来的位置；左边两列是 旧/新 行号
-- 改动了不止一个文件：先弹出文件列表（有 fzf 用 fzf）选一个再看，浮窗里按 b 回到列表；
-- 来回切换时记得位置：列表的光标停在刚看的那个文件上，再进某个文件时回到上次看到的地方
local M = {}

local ns = vim.api.nvim_create_namespace("gitdiff")
local views = {} -- buf -> { info = { { kind, old, new }, ... }, w = 行号列宽 }，给 statuscolumn 用

local function git(root, args, input)
    local cmd = { "git", "-C", root, "-c", "color.ui=never", "-c", "core.quotepath=off" }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { text = true, stdin = input }):wait(15000) -- text=true：CRLF 换成 LF，不会满屏 ^M
    return res.stdout or "", res.code
end

-- 先看当前文件所在的仓库，不行再看 nvim 的工作目录
local function repo_root()
    local dirs, name = {}, vim.api.nvim_buf_get_name(0)
    if vim.bo.buftype == "" and name ~= "" then
        dirs[#dirs + 1] = vim.fs.dirname(name)
    end
    dirs[#dirs + 1] = vim.fn.getcwd()
    for _, d in ipairs(dirs) do
        if vim.fn.isdirectory(d) == 1 then
            local out, code = git(d, { "rev-parse", "--show-toplevel" })
            if code == 0 then
                return vim.trim(out)
            end
        end
    end
end

-- 和谁比：有提交就是 HEAD；刚 git init 还没有提交时和空树比（于是所有文件都是新增）
local function base_rev(root)
    local _, code = git(root, { "rev-parse", "--verify", "-q", "HEAD" })
    if code == 0 then
        return "HEAD"
    end
    local tree = git(root, { "hash-object", "-t", "tree", "--stdin" }, "")
    return vim.trim(tree)
end

local function label_of(xy)
    if xy == "??" then
        return "未跟踪"
    elseif xy:find("U") or xy == "AA" or xy == "DD" then
        return "冲突"
    elseif xy:find("R") then
        return "重命名"
    elseif xy:find("D") then
        return "删除"
    elseif xy:find("[AC]") then
        return "新增"
    end
    return "修改"
end

local function pad(s, w)
    return s .. (" "):rep(w - vim.fn.strdisplaywidth(s))
end

-- 所有有改动的文件：{ xy, path, old?, label, display }
local function list_changes(root, base)
    local out = git(root, { "status", "--porcelain=v1", "-z", "--untracked-files=all" })
    local parts, files, i = vim.split(out, "\0", { plain = true }), {}, 1
    while i <= #parts do
        local e = parts[i]
        if #e > 3 then
            local f = { xy = e:sub(1, 2), path = e:sub(4) }
            if f.xy:find("[RC]") then -- -z 格式：R  新路径 \0 旧路径 \0
                i = i + 1
                f.old = parts[i]
            end
            files[#files + 1] = f
        end
        i = i + 1
    end

    -- 每个文件加了几行、删了几行（未跟踪的文件 git diff 不管，不显示）
    local stat = {}
    local nums = vim.split((git(root, { "diff", base, "-M", "--numstat", "-z", "--no-ext-diff" })), "\0", { plain = true })
    local j = 1
    while j <= #nums do
        local a, d, p = nums[j]:match("^(%S+)\t(%S+)\t(.*)$")
        if a then
            if p == "" then -- 重命名：后面跟着 旧路径 \0 新路径
                p = nums[j + 2]
                j = j + 2
            end
            if p then
                stat[p] = a == "-" and "二进制" or ("+" .. a .. " -" .. d)
            end
        end
        j = j + 1
    end

    for _, f in ipairs(files) do
        f.label = label_of(f.xy)
        local shown = f.old and (f.old .. " → " .. f.path) or f.path
        f.display = pad(f.label, 7) .. pad(stat[f.path] or "", 10) .. shown
    end
    return files
end

-- 把 git diff 的输出（上下文拉满，所以是整个文件）拆成：纯文本行 + 每行的种类和新旧行号
local function parse_diff(out)
    local text, info, header, adds, dels = {}, {}, {}, 0, 0
    local old, new, in_hunk
    out = out:gsub("\n+$", "")
    for _, l in ipairs(vim.split(out, "\n", { plain = true })) do
        local o, n = l:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
        if o then
            old, new, in_hunk = tonumber(o), tonumber(n), true
        elseif not in_hunk then
            header[#header + 1] = l
        else
            local c = l:sub(1, 1)
            if c == "+" then
                text[#text + 1], info[#info + 1] = l:sub(2), { kind = "add", new = new }
                new, adds = new + 1, adds + 1
            elseif c == "-" then
                text[#text + 1], info[#info + 1] = l:sub(2), { kind = "del", old = old }
                old, dels = old + 1, dels + 1
            elseif c == "\\" then -- “\ No newline at end of file”
                text[#text + 1], info[#info + 1] = l, { kind = "note" }
            else -- 上下文行；diff.suppressBlankEmpty 开着时空行没有前导空格
                text[#text + 1], info[#info + 1] = l:sub(2), { kind = "ctx", old = old, new = new }
                old, new = old + 1, new + 1
            end
        end
    end
    if #text == 0 then -- 没有 @@：二进制、空文件、只改了权限……直接把 git 的说明摆出来
        for _, l in ipairs(header) do
            if l:find("^Binary files") then
                l = "二进制文件，不显示内容"
            end
            if l ~= "" and not l:find("^diff %-%-git") and not l:find("^index ") then
                text[#text + 1], info[#info + 1] = l, { kind = "note" }
            end
        end
        if #text == 0 then
            text[1], info[1] = "（没有可显示的改动）", { kind = "note" }
        end
    end
    return text, info, adds, dels
end

-- statuscolumn：旧行号 新行号 +/-
function M.stc()
    local v = views[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
    local it = v and vim.v.virtnum == 0 and v.info[vim.v.lnum]
    if not it then
        return ""
    end
    local fmt = "%" .. v.w .. "s"
    local old = it.old and fmt:format(it.old) or fmt:format("")
    local new = it.new and fmt:format(it.new) or fmt:format("")
    local mark, grp = " ", "LineNr"
    if it.kind == "add" then
        mark, grp = "+", "GitDiffAdd"
    elseif it.kind == "del" then
        mark, grp = "-", "GitDiffDel"
    end
    return "%#LineNr#" .. old .. " " .. new .. " %#" .. grp .. "#" .. mark .. "%* "
end

-- mem（按 b 来回切换时共用）：mem.pos[路径] = 上次离开时的视图（winsaveview），mem.last = 列表里上次选的序号
local function show(root, base, f, back, mem)
    mem = mem or { pos = {} }
    local out
    if f.xy == "??" then
        out = git(root, { "diff", "--no-index", "--no-color", "--no-ext-diff", "-U1000000", "--", "/dev/null", f.path })
    else
        local args = { "diff", base, "-M", "--no-color", "--no-ext-diff", "-U1000000", "--" }
        if f.old then
            args[#args + 1] = f.old -- 重命名要把新旧两个路径都给 git，它才认得出来
        end
        args[#args + 1] = f.path
        out = git(root, args)
    end
    local text, info, adds, dels = parse_diff(out)

    -- 自己的高亮组；:colorscheme 会清掉，所以每次打开都（重新）定义
    vim.api.nvim_set_hl(0, "GitDiffAdd", { link = "diffAdded", default = true })
    vim.api.nvim_set_hl(0, "GitDiffDel", { link = "diffRemoved", default = true })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
    local maxn, first, kinds = 1, nil, {}
    for i, it in ipairs(info) do
        kinds[i] = it.kind
        maxn = math.max(maxn, it.old or 0, it.new or 0)
        if it.kind == "add" or it.kind == "del" then
            first = first or i
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = it.kind == "add" and "DiffAdd" or "DiffDelete" })
        elseif it.kind == "note" then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #text[i], hl_group = "Comment" })
        end
    end
    views[buf] = { info = info, w = math.max(2, #tostring(maxn)) }
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].tabstop = 4
    local ft = vim.filetype.match({ filename = f.path })
    if ft then
        vim.bo[buf].syntax = ft -- 只开语法高亮，不触发 FileType（免得 java_lite 的按键挂到这个缓冲区上）
    end
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            views[buf] = nil
        end,
    })

    local width = math.max(1, math.floor(vim.o.columns * 0.9))
    local height = math.max(1, math.floor(vim.o.lines * 0.85))
    local footer = " q 关闭 · ]c [c 下一处 / 上一处改动" .. (back and " · b 文件列表" or "") .. " "
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2) - 1,
        style = "minimal",
        border = "rounded",
        title = (" Diff  %s  +%d -%d "):format(f.old and (f.old .. " → " .. f.path) or f.path, adds, dels),
        title_pos = "center",
        footer = footer,
        footer_pos = "center",
    })
    vim.wo[win].wrap = false
    vim.wo[win].statuscolumn = "%!v:lua.require'gitdiff'.stc()"

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            mem.pos[f.path] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
            vim.api.nvim_win_close(win, true)
        end
    end
    local function map(lhs, fn)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        map(lhs, close)
    end
    if back then
        map("b", function()
            close()
            back()
        end)
    end

    -- ]c / [c：跳到下一处 / 上一处改动的第一行（连在一起的红绿行算一处）
    local function changed(i)
        return kinds[i] == "add" or kinds[i] == "del"
    end
    local function goto_change(dir)
        local n, i = #kinds, vim.api.nvim_win_get_cursor(win)[1]
        if dir > 0 then
            while i <= n and changed(i) do
                i = i + 1
            end
            while i <= n and not changed(i) do
                i = i + 1
            end
            if i > n then
                return
            end
        else
            while i >= 1 and changed(i) do
                i = i - 1
            end
            while i >= 1 and not changed(i) do
                i = i - 1
            end
            if i < 1 then
                return
            end
            while i > 1 and changed(i - 1) do
                i = i - 1
            end
        end
        vim.api.nvim_win_set_cursor(win, { i, 0 })
    end
    map("]c", function()
        goto_change(1)
    end)
    map("[c", function()
        goto_change(-1)
    end)

    -- 以前看过这个文件（按 b 出去又进来）：回到当时的光标和滚动位置；
    -- 否则停在第一处改动上，它上面留三分之一窗口的上文；文件末尾的改动不让窗口下半截空着
    local saved = mem.pos[f.path]
    if saved then
        local lnum = math.max(1, math.min(saved.lnum, #text))
        vim.api.nvim_win_call(win, function()
            vim.fn.winrestview({ topline = math.max(1, math.min(saved.topline, lnum)), lnum = lnum, col = saved.col, leftcol = saved.leftcol })
        end)
    elseif first then
        local top = math.max(1, math.min(first - math.floor(height / 3), #text - height + 1))
        vim.api.nvim_win_call(win, function()
            vim.fn.winrestview({ topline = top, lnum = first, col = 0 })
        end)
    end
    -- 焦点离开（比如用鼠标点了窗口外面）就关掉
    vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

function M.open()
    if vim.fn.executable("git") == 0 then
        vim.notify("找不到 git", vim.log.levels.ERROR)
        return
    end
    local root = repo_root()
    if not root then
        vim.notify("这里不在 git 仓库里", vim.log.levels.WARN)
        return
    end
    local base = base_rev(root)
    local files = list_changes(root, base)
    if #files == 0 then
        vim.notify("没有未提交的改动", vim.log.levels.INFO)
        return
    end
    if #files == 1 then
        show(root, base, files[1])
        return
    end

    local mem = { pos = {} } -- 按 b 回来时，列表的光标和每个文件的位置都还在
    local function choose()
        local function on_choice(it)
            mem.last = it.i
            show(root, base, it.f, choose, mem)
        end
        local items = {}
        for i, f in ipairs(files) do
            items[i] = { display = f.display, f = f, i = i }
        end
        local title = ("选一个文件看改动（共 %d 个）"):format(#files)
        if vim.fn.executable("fzf") == 1 then
            require("java_lite.pick").choose(items, title, on_choice, mem.last)
        else
            vim.ui.select(items, {
                prompt = title,
                format_item = function(it)
                    return it.display
                end,
            }, function(it)
                if it then
                    on_choice(it)
                end
            end)
        end
    end
    choose()
end

return M
