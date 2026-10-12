-- 方法跳转：]f / [f 在方法间移动，<leader>o 列出本文件的类和方法
-- 每次按键现扫现用，不缓存、不常驻
local scan = require("java_lite.scan")

local M = {}

local function buf_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- 跳到本文件的某个符号
local function goto_item(it)
    vim.cmd("normal! m'") -- 记进跳转列表，<C-o> 能回来
    vim.api.nvim_win_set_cursor(0, { it.lnum, it.col })
    vim.cmd("normal! zvzz")
end

local function methods(buf)
    local out = {}
    for _, s in ipairs(scan.symbols(buf_lines(buf))) do
        if s.kind == "method" then
            out[#out + 1] = s
        end
    end
    return out
end

function M.next_method(count)
    local cur, hit, seen = vim.api.nvim_win_get_cursor(0)[1], nil, 0
    for _, s in ipairs(methods(0)) do
        if s.lnum > cur then
            hit, seen = s, seen + 1
            if seen == count then
                break
            end
        end
    end
    if hit then
        goto_item(hit)
    end
end

function M.prev_method(count)
    local cur, hit, seen = vim.api.nvim_win_get_cursor(0)[1], nil, 0
    local ms = methods(0)
    for k = #ms, 1, -1 do
        if ms[k].lnum < cur then
            hit, seen = ms[k], seen + 1
            if seen == count then
                break
            end
        end
    end
    if hit then
        goto_item(hit)
    end
end

function M.outline()
    local items = {}
    for _, s in ipairs(scan.symbols(buf_lines(0))) do
        items[#items + 1] = {
            lnum = s.lnum,
            col = s.col,
            display = string.format("%5d  %s%s", s.lnum, ("  "):rep(s.depth), s.text),
        }
    end
    require("java_lite.pick").choose(items, "Java 大纲", goto_item)
end

local function project_root(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    local start = name ~= "" and name or vim.uv.cwd()
    return vim.fs.root(start, ".git")
        or vim.fs.root(start, { "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts" })
        or (name ~= "" and vim.fs.dirname(name) or vim.uv.cwd())
end

M.project_root = project_root

return M
