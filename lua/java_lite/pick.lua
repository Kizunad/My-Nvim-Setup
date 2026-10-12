-- 候选列表选择器：有 fzf 就在浮窗里跑 fzf（模糊搜索，鼠标也能点；用完进程即退出），
-- 没有 fzf 就退回 location list。items = { { file?, lnum, col, display }, ... }
local M = {}

local function loclist(items, title)
    local list, bufnr = {}, vim.api.nvim_get_current_buf()
    for _, it in ipairs(items) do
        list[#list + 1] = { filename = it.file, bufnr = not it.file and bufnr or nil, lnum = it.lnum, col = it.col + 1, text = it.display }
    end
    vim.fn.setloclist(0, {}, " ", { title = title, items = list })
    vim.cmd("lopen")
end

local function fzf(items, title, on_choice)
    local infile, outfile = vim.fn.tempname(), vim.fn.tempname()
    local rows = {}
    for i, it in ipairs(items) do
        rows[i] = i .. "\t" .. it.display:gsub("\t", " ") -- 行首的序号用来映射回 items
    end
    vim.fn.writefile(rows, infile)

    local origin = vim.api.nvim_get_current_win()
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.6)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
    })

    local cmd = string.format(
        "fzf --delimiter='\\t' --with-nth=2.. --tiebreak=index --layout=reverse --prompt=%s < %s > %s",
        vim.fn.shellescape(title .. "> "),
        vim.fn.shellescape(infile),
        vim.fn.shellescape(outfile)
    )
    vim.fn.termopen({ "sh", "-c", cmd }, {
        on_exit = function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
            local sel = vim.fn.filereadable(outfile) == 1 and vim.fn.readfile(outfile)[1] or nil
            vim.fn.delete(infile)
            vim.fn.delete(outfile)
            if vim.api.nvim_win_is_valid(origin) then
                vim.api.nvim_set_current_win(origin)
            end
            vim.cmd.stopinsert()
            local idx = sel and tonumber(sel:match("^(%d+)\t"))
            if idx and items[idx] then
                on_choice(items[idx])
            end
        end,
    })
    vim.cmd.startinsert()
end

function M.choose(items, title, on_choice)
    if #items == 0 then
        return
    end
    if vim.fn.executable("fzf") == 1 then
        fzf(items, title, on_choice)
    else
        loclist(items, title)
    end
end

return M
