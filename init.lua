
-- clipboard 配置
vim.opt.clipboard = "unnamedplus"


-- Tab 缩进为 4 个空格
vim.opt.tabstop = 4        -- 显示 Tab 宽度
vim.opt.shiftwidth = 4     -- 自动缩进宽度
vim.opt.softtabstop = 4    -- Tab 键插入空格数
vim.opt.expandtab = true   -- Tab 替换为空格


-- 鼠标：所有模式下可点击定位、拖选、滚轮、拖动分屏边界、右键菜单
-- （终端自带的选择/复制：按住 Shift 再拖选）
vim.opt.mouse = "a"


-- leader 键设为空格（要在加载插件之前设置）
vim.g.mapleader = " "


-- 插件管理器 lazy.nvim（首次启动自动 clone；没网时跳过，不影响其余配置）
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
    vim.fn.system({
        "git", "clone", "--filter=blob:none", "--branch=stable",
        "https://github.com/folke/lazy.nvim.git", lazypath,
    })
end
vim.opt.rtp:prepend(lazypath)


-- 文件树 nvim-tree：单击展开/折叠目录、预览文件；<CR> 打开并跳到文件
local function tree_on_attach(bufnr)
    local api = require("nvim-tree.api")
    api.config.mappings.default_on_attach(bufnr)

    local function map(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = bufnr, noremap = true, silent = true, nowait = true, desc = "nvim-tree: " .. desc })
    end

    -- 单击：只在“同一行按下并松开”、且点在有内容的行上时触发
    -- （拖动边界/框选/点树下方空白处都不会误开文件；空白处的 m.line 会被钳到最后一行，不能用它判断）
    map("<LeftRelease>", function()
        local m = vim.fn.getmousepos()
        local last_row = vim.fn.line("$") - vim.fn.line("w0") + 1   -- 树内容最后一行在窗口里的行号
        if m.winid ~= vim.api.nvim_get_current_win() or m.winrow > last_row or m.line ~= vim.fn.line(".") then
            return
        end
        api.node.open.preview()
    end, "单击打开/展开")
    -- 双击会连发两次点击，默认的双击映射会让目录来回折叠，这里禁掉
    map("<2-LeftMouse>", "<Nop>", "忽略双击")
end

local ok, lazy = pcall(require, "lazy")
if ok then
    lazy.setup({
        {
            -- 配色 catppuccin macchiato：柔和不刺眼（正文对比度≈9.9，不是默认主题的 14），
            -- 关键字/类型/函数/常量/字符串/注释各有各的颜色，注释和浮窗边框也看得清
            -- 想换：:colorscheme catppuccin-frappe / catppuccin-mocha / habamax（habamax 是 nvim 自带，零成本）
            "catppuccin/nvim",
            name = "catppuccin",
            lazy = false,
            priority = 1000, -- 主题要比其他插件先加载
            opts = { flavour = "macchiato" },
            config = function(_, opts)
                require("catppuccin").setup(opts)
                vim.cmd.colorscheme("catppuccin")
            end,
        },
        {
            "nvim-tree/nvim-tree.lua",
            lazy = false,
            config = function(_, opts)
                require("nvim-tree").setup(opts)
                -- nvim-tree 的小毛病：树跟随当前文件（update_focused_file）展开 java/com/example 这种合并行时，
                -- “已展开”只记在最后一层上，箭头却读第一层，结果内容明明展开了还显示 ▸。让箭头也读最后一层
                local ok, pad = pcall(require, "nvim-tree.renderer.components.padding")
                if ok and pad.get_arrows then
                    local get_arrows = pad.get_arrows
                    pad.get_arrows = function(node)
                        if not (node.group_next and node.last_group_node) then
                            return get_arrows(node)
                        end
                        local head_open = node.open
                        node.open = node:last_group_node().open
                        local ok_arrow, arrows = pcall(get_arrows, node)
                        node.open = head_open
                        if not ok_arrow then
                            error(arrows, 0)
                        end
                        return arrows
                    end
                end
            end,
            opts = {
                on_attach = tree_on_attach,
                -- 宽度：默认 32，鼠标拖过之后记在 ~/.local/state/nvim/nvim-tree-width（lua/tree_width.lua），
                -- 之后重启 / 关了再开树都沿用；打开文件不再重设宽度（resize_window=false），
                -- 开关树也不会把其他窗口重新均分（preserve_window_proportions）
                view = { width = require("tree_width").initial(32), preserve_window_proportions = true },
                actions = { open_file = { resize_window = false } },
                update_focused_file = { enable = true },   -- 树跟随当前文件
                renderer = {
                    -- Java 包目录 com/example/app 里每层都只有一个子目录时，合并成一行 com/example/app，
                    -- 点一下就整条展开；L 可以临时拆开 / 合并当前这一行
                    group_empty = true,
                    indent_markers = { enable = true },
                    icons = {
                        -- 不依赖 Nerd Font；换了 Nerd Font 终端字体后可把 file/folder/git 改成 true
                        show = { file = false, folder = false, folder_arrow = true, git = false },
                        glyphs = { folder = { arrow_closed = "▸", arrow_open = "▾" } },
                    },
                },
            },
        },
    }, {
        checker = { enabled = false },
        change_detection = { notify = false },
    })
    require("tree_width").watch()
end

vim.keymap.set("n", "<leader>e", "<cmd>NvimTreeFindFileToggle<CR>", { silent = true, desc = "文件树开关" })


-- 普通编辑窗口（不是文件树、不是浮窗）：优先 prefer，再是上一个窗口，最后取第一个
local function editing_window(prefer)
    local function usable(w)
        return w ~= nil
            and w ~= 0
            and vim.api.nvim_win_is_valid(w)
            and vim.api.nvim_win_get_config(w).relative == ""
            and vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "NvimTree"
    end
    if usable(prefer) then
        return prefer
    end
    local prev = vim.fn.win_getid(vim.fn.winnr("#"))
    if usable(prev) then
        return prev
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if usable(w) then
            return w
        end
    end
end


-- 前进 / 后退：就是跳转历史（Ctrl-O / Ctrl-I），]f、[f、搜索、从文件树点开的文件都算
-- 键位：Alt+← / Alt+→（和浏览器一样）、鼠标侧键 <X1Mouse> / <X2Mouse>
-- 注意：WezTerm 不把侧键传给程序，nvim 0.10 的终端界面也不认，所以侧键要先在 Windows 侧映射成 Alt+←/→（见速查表）；
-- <X1Mouse>/<X2Mouse> 留着，哪天终端或 nvim 支持了就直接生效
local function jump_history(forward)
    local win = 0
    if vim.bo.filetype == "NvimTree" then
        win = editing_window() -- 焦点在树里时，历史属于编辑窗口；焦点仍留在树里
        if not win then
            return
        end
    end
    -- 数字前缀可用：3<A-Left> 后退三步。已经到头了就什么也不做（不报错）
    vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, "normal! " .. vim.v.count1 .. (forward and "\t" or "\15"))
    end)
end

for lhs, forward in pairs({ ["<M-Left>"] = false, ["<X1Mouse>"] = false, ["<M-Right>"] = true, ["<X2Mouse>"] = true }) do
    vim.keymap.set("n", lhs, function()
        jump_history(forward)
    end, { silent = true, desc = forward and "前进（跳转历史）" or "后退（跳转历史）" })
end


-- ranger 选文件：在浮窗里跑 ranger，回车选中的文件会在 nvim 里打开
local function goto_main_window(prefer)
    -- 焦点在文件树里时，换到一个普通编辑窗口，免得文件把树顶掉
    if vim.bo.filetype ~= "NvimTree" then
        return
    end
    local w = editing_window(prefer)
    if w then
        vim.api.nvim_set_current_win(w)
    else
        vim.cmd("rightbelow vnew")
    end
end

local function ranger_pick()
    if vim.fn.executable("ranger") == 0 then
        vim.notify("找不到 ranger（pipx install ranger-fm）", vim.log.levels.ERROR)
        return
    end

    local chooser = vim.fn.tempname()
    local cmd = { "ranger", "--choosefiles=" .. chooser }
    local cur = vim.api.nvim_buf_get_name(0)
    if vim.bo.buftype == "" and vim.fn.filereadable(cur) == 1 then
        table.insert(cmd, "--selectfile=" .. cur)   -- 从当前文件所在目录开始，并选中它
    end

    -- 从文件树里启动时，先记下原来所在的编辑窗口：浮窗关掉后“上一个窗口”就不是它了
    local origin = vim.bo.filetype == "NvimTree" and editing_window() or nil

    local width = math.floor(vim.o.columns * 0.9)
    local height = math.floor(vim.o.lines * 0.85)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2) - 1,
        style = "minimal",
        border = "rounded",
    })

    vim.fn.termopen(cmd, {
        on_exit = function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
            local files = vim.fn.filereadable(chooser) == 1 and vim.fn.readfile(chooser) or {}
            vim.fn.delete(chooser)
            if #files > 0 then
                goto_main_window(origin)
            end
            for _, f in ipairs(files) do
                vim.cmd.edit(vim.fn.fnameescape(f))
            end
        end,
    })
    vim.cmd.startinsert()
end

vim.api.nvim_create_user_command("Ranger", ranger_pick, { desc = "用 ranger 选文件" })
vim.keymap.set("n", "<leader>r", ranger_pick, { silent = true, desc = "ranger 选文件" })


-- 空格 t：弹出临时终端（浮窗里的 shell，退出即销毁），逻辑在 lua/tmpterm.lua，按键时才加载
vim.keymap.set("n", "<leader>t", function()
    require("tmpterm").open()
end, { silent = true, desc = "临时终端" })


-- :Diff：浮窗里看 git 没提交的改动（整个文件，红 = 删掉的行，绿 = 新增的行；改了多个文件先选一个），
-- 逻辑在 lua/gitdiff.lua，用到时才加载。用户命令必须大写开头，所以再加个缩写：手滑敲小写 :diff 也走它
-- （小写 :diff 本来只是 :diffupdate 的缩写；:diffu 以上的写法不受影响）
vim.api.nvim_create_user_command("Diff", function()
    require("gitdiff").open()
end, { desc = "浮窗看 git 未提交的改动" })
vim.cmd([[cnoreabbrev <expr> diff getcmdtype() ==# ':' && getcmdline() ==# 'diff' ? 'Diff' : 'diff']])


-- 空格 h：配置速查（help），内容在 lua/cheatsheet.lua，按键时才加载
vim.keymap.set("n", "<leader>h", function()
    require("cheatsheet").show()
end, { silent = true, desc = "配置速查" })
