-- 文件树宽度持久化：用鼠标拖宽 / 拖窄后记到 stdpath("state")/nvim-tree-width，
-- 之后点文件、关了再开树、重启 nvim 都沿用。启动时只读一个几字节的文件，没有后台进程。
local M = {}

local FILE = vim.fn.stdpath("state") .. "/nvim-tree-width"
local MIN, MAX = 10, 120

local function load()
    local f = io.open(FILE)
    if not f then
        return nil
    end
    local n = tonumber(f:read("*l"))
    f:close()
    if n and n >= MIN and n <= MAX then
        return math.floor(n)
    end
end

-- 给 nvim-tree 的 view.width：没存过就用 default；存过就用存的值，
-- 但终端太窄时最多占一半（只限制这一次打开，不会改写存下来的值）
function M.initial(default)
    local saved = load()
    if not saved then
        return default
    end
    return function()
        return math.min(saved, math.max(MIN, math.floor(vim.o.columns * 0.5)))
    end
end

local latest, pending
local function save(width)
    latest = width
    if pending then
        return
    end
    pending = true -- 拖动时事件很密，攒 300ms 只写一次最后的值
    vim.defer_fn(function()
        pending = false
        pcall(vim.fn.mkdir, vim.fn.fnamemodify(FILE, ":h"), "p")
        pcall(vim.fn.writefile, { tostring(latest) }, FILE)
    end, 300)
end

function M.watch()
    local ok, api = pcall(require, "nvim-tree.api")
    if not ok then
        return -- 插件还没装好（首次启动没网）
    end

    -- 树窗口上一次已知的宽度：nvim-tree 自己设的（打开 / :NvimTreeResize）会更新它；
    -- 之后窗口宽度和它不一样，就是用户拖的。只是高度变化（改终端高度、开 quickfix）时宽度不变，不会误存
    local seen
    api.events.subscribe(api.events.Event.Resize, function(size)
        seen = size
    end)

    local cols = vim.o.columns
    vim.api.nvim_create_autocmd("WinResized", {
        group = vim.api.nvim_create_augroup("TreeWidth", { clear = true }),
        callback = function()
            local terminal_resized = cols ~= vim.o.columns
            cols = vim.o.columns
            if not seen then
                return
            end
            for _, w in ipairs(vim.v.event.windows) do
                if vim.api.nvim_win_is_valid(w) and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "NvimTree" then
                    local width = vim.api.nvim_win_get_width(w)
                    if terminal_resized then
                        seen = width -- 终端整体缩放时树可能被动变窄，那不是用户的选择，不存
                    elseif width ~= seen then
                        seen = width
                        if width >= MIN and width <= MAX then
                            api.tree.resize({ width = width }) -- 让 nvim-tree 记住，关了再开沿用这个宽度
                            save(width)
                        end
                    end
                    return
                end
            end
        end,
    })
end

return M
