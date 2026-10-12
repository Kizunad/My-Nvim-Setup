-- 空格 + h：弹出一个浮窗，列出我们对 nvim 做的修改和快捷键
-- 新增/修改快捷键后，记得同步更新下面的 sections
local M = {}

-- 每节 { 标题, { { 键, 说明 }, ... } }；键那一列只放 ASCII，保证对齐
local sections = {
    { "鼠标", {
        { "点击 / 拖选 / 滚轮", "定位光标、选择文本、滚动" },
        { "拖动分屏边界", "调整窗口大小" },
        { "右键", "弹出菜单（复制 / 粘贴）" },
        { "Shift + 拖选", "用终端自带的选择和复制" },
        { "Alt + Left/Right", "后退 / 前进（跳转历史：]f、[f、搜索、点文件树开的文件都算，可加数字）" },
        { "Mouse side btns", "WezTerm 不传侧键给 nvim：要在 Windows 侧把侧键映射成 Alt+Left/Right" },
    } },
    { "通用", {
        { "Space e", "开关文件树" },
        { "Space r", "用 ranger 选文件（也可以 :Ranger）" },
        { "Space t", "弹出临时终端" },
        { "Space h", "显示这个速查表" },
    } },
    { "文件树（Space e）", {
        { "单击", "目录：展开 / 折叠；文件：预览，焦点留在树里" },
        { "Enter", "打开文件并跳到编辑窗口" },
        { "com/example/app", "Java 包目录一层套一层、每层只有一个子目录时合并成一行，点一下整条展开；L 拆开 / 合并当前这行" },
        { "拖动树的右边界", "调宽 / 调窄，宽度会记住：点文件、关了再开树、重启 nvim 都沿用" },
        { "a / d / r", "新建 / 删除 / 重命名" },
        { "H", "显示 / 隐藏以 . 开头的文件" },
        { "-", "回到上级目录（点第一行 .. 也行）" },
        { "g?", "文件树自带的完整按键帮助" },
        { "q", "关闭文件树" },
    } },
    { "ranger（Space r）", {
        { "h j k l", "移动；l 或 Enter 进入目录 / 选中文件" },
        { "Space", "标记多个文件，再按 Enter 一起打开" },
        { "v", "标记当前目录所有文件" },
        { "zh", "显示 / 隐藏隐藏文件" },
        { "q", "取消，什么也不打开" },
        { "?", "ranger 自带帮助（鼠标点击也可用）" },
    } },
    { "临时终端（Space t）", {
        { "Ctrl-D / exit", "退出，终端整个销毁，不留后台 shell" },
        { "Ctrl-\\ Ctrl-N", "回到普通模式（可滚动回看、复制），i 回到输入" },
        { "q", "普通模式下强制关闭，连同里面正在跑的命令" },
        { "Space t", "普通模式下关闭；焦点在别处时回到已开的终端" },
    } },
    { "Java 文件里（java_lite）", {
        { "]f / [f", "下一个 / 上一个方法，可加计数，如 3]f" },
        { "Space o", "本文件的类和方法列表（fzf，可模糊搜索）" },
        { "Space d", "悬浮窗看光标下（或选中的）类 / 方法的定义，带 Javadoc 注释" },
        { "  on a variable", "光标在局部变量 / 参数 / 字段 / 枚举常量上：直接跳到它的声明（按作用域找，同名的不会串；Alt+Left 回来）" },
        { "  in float", "b 浏览器开文档；q / Esc 或点窗口外关闭；再按 Space d 继续看里面的类型" },
        { "  sources", "项目 → JDK 的 src.zip → Gradle 缓存里的 sources jar；都没有就开在线文档" },
        { "Ctrl-O", "跳转之后回到原来的位置" },
    } },
    { "其他设置", {
        { "leader 键", "空格" },
        { "剪贴板", "和系统共用（clipboard = unnamedplus）" },
        { "缩进", "Tab 输入 4 个空格" },
        { "终端回看", "只保留 2000 行（默认 10000），省内存" },
        { "配色", "catppuccin macchiato；:colorscheme catppuccin-frappe / -mocha / habamax 可试别的" },
    } },
    { "配置文件（~/.config/nvim/）", {
        { "init.lua", "主配置：鼠标、插件管理器、文件树、ranger" },
        { "lua/java_lite/", "Java 轻量高亮 + 方法跳转 + 看定义 / 文档（doc.lua）+ 变量声明（vars.lua）" },
        { "lua/tmpterm.lua", "临时终端" },
        { "lua/tree_width.lua", "记住文件树宽度（存在 ~/.local/state/nvim/nvim-tree-width）" },
        { "lua/cheatsheet.lua", "这个速查表" },
    } },
}

function M.show()
    local key_w = 0
    for _, sec in ipairs(sections) do
        for _, it in ipairs(sec[2]) do
            key_w = math.max(key_w, vim.fn.strdisplaywidth(it[1]))
        end
    end

    local lines, marks = {}, {} -- marks = { { 行(0 基), 起始列, 结束列, 高亮组 }, ... }
    for i, sec in ipairs(sections) do
        if i > 1 then
            lines[#lines + 1] = ""
        end
        lines[#lines + 1] = " " .. sec[1]
        marks[#marks + 1] = { #lines - 1, 0, #lines[#lines], "Title" }
        for _, it in ipairs(sec[2]) do
            local pad = (" "):rep(key_w - vim.fn.strdisplaywidth(it[1]))
            lines[#lines + 1] = "   " .. it[1] .. pad .. "  " .. it[2]
            marks[#marks + 1] = { #lines - 1, 3, 3 + #it[1], "Special" }
        end
    end

    local text_w = 0
    for _, l in ipairs(lines) do
        text_w = math.max(text_w, vim.fn.strdisplaywidth(l))
    end
    local width = math.max(1, math.min(text_w + 2, vim.o.columns - 4))
    local height = math.max(1, math.min(#lines, vim.o.lines - 6)) -- 终端很小时也别让 nvim_open_win 报错

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("cheatsheet")
    for _, m in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2) - 1,
        style = "minimal",
        border = "rounded",
        title = " 配置速查  (q / Esc 关闭，点窗口外也行) ",
        title_pos = "center",
    })
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    for _, lhs in ipairs({ "q", "<Esc>", "<leader>h" }) do
        vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true })
    end
    -- 焦点离开（比如用鼠标点了窗口外面）就关掉
    vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

return M
