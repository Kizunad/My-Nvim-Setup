-- 空格 + t：弹出一个临时终端（浮窗里跑 $SHELL，在 nvim 当前目录打开）
-- “临时”的意思：shell 一退出（exit / Ctrl-D）或按 q，窗口和缓冲区整个销毁，不留后台进程；
-- 回看缓冲只留 2000 行（终端默认 10000 行，输出刷屏时会白白多占几 MB 内存）
local M = {}

local win -- 当前打开的临时终端窗口；同一时间只保留一个

local function close(w, b)
    if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_close(w, true)
    end
    if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true }) -- 终端缓冲区被销毁时，里面的 shell 一并结束
    end
    if win == w then
        win = nil
    end
end

function M.open()
    -- 已经开着（比如焦点被鼠标点到窗口外了）：回到它，不再开第二个
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        vim.cmd.startinsert()
        return
    end

    local width = math.floor(vim.o.columns * 0.85)
    local height = math.floor(vim.o.lines * 0.75)
    local buf = vim.api.nvim_create_buf(false, true)
    local w = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = math.max(1, width),
        height = math.max(1, height),
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2) - 1,
        style = "minimal",
        border = "rounded",
        title = " 临时终端  Ctrl-D 退出 · Ctrl-\\ Ctrl-N 回普通模式 · 普通模式按 q 关闭 ",
        title_pos = "center",
    })
    win = w

    vim.fn.termopen(vim.o.shell, {
        cwd = vim.fn.getcwd(),
        on_exit = function()
            close(w, buf)
        end,
    })

    -- 要在 termopen 之后设：创建终端缓冲区时 nvim 会用全局 scrollback 覆盖缓冲区局部值，提前设无效
    vim.bo[buf].scrollback = 2000

    -- 普通模式（Ctrl-\ Ctrl-N 之后）：q 或 空格 t 直接关掉并结束这个终端
    for _, lhs in ipairs({ "q", "<leader>t" }) do
        vim.keymap.set("n", lhs, function()
            close(w, buf)
        end, { buffer = buf, nowait = true, silent = true, desc = "关闭临时终端" })
    end
    vim.cmd.startinsert()
end

return M
