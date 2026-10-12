local M = {}

-- java.vim 自带的分组有两处不好看：public/static/class 和类型名同色（都归 StorageClass/Type），
-- final/abstract 这类（javaConceptKind）还被指到 NonText，暗灰得像被禁用。统一指到 Keyword，和 return/if 同一色系
local MODIFIER_GROUPS = { "javaScopeDecl", "javaStorageClass", "javaConceptKind", "javaMethodDecl" }

local function link_modifiers()
    for _, g in ipairs(MODIFIER_GROUPS) do
        vim.cmd("highlight link " .. g .. " Keyword") -- 不加 default，才能盖过 java.vim 自己的 hi def link
    end
end

local colorscheme_hooked = false

-- 高亮：复用 nvim 自带的 syntax/java.vim（纯正则，不占额外内存），只补两条规则：
--   javaTypeName  驼峰类名（Foo、HttpClient；全大写的常量和单字母泛型 T 不算）
--   javaCall      后面跟着 ( 的标识符：方法声明、方法调用、构造调用
-- javaCall 放在后面定义，同一位置两者都匹配时它优先；控制关键字用负向预查排除，不抢 if( / for( 的颜色
function M.highlight()
    vim.cmd([[
        syntax match javaTypeName /\<[A-Z][A-Za-z0-9_$]*[a-z][A-Za-z0-9_$]*\>/
        syntax match javaCall /\%(\<\%(if\|for\|while\|switch\|catch\|synchronized\|return\|throw\|assert\|new\|super\|this\|case\|else\)\>\)\@!\<[A-Za-z_$][A-Za-z0-9_$]*\ze\s*(/
        highlight default link javaTypeName Type
        highlight default link javaCall Function
    ]])
    link_modifiers()
    if not colorscheme_hooked then
        colorscheme_hooked = true
        -- :colorscheme 会清掉非 default 的 link，换主题后补回来（高亮组是全局的，补一次就够）
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = vim.api.nvim_create_augroup("JavaLiteColors", { clear = true }),
            callback = link_modifiers,
        })
    end
end

-- 跳转：只挂缓冲区局部按键；扫描器、选择器等到第一次按键才 require
function M.attach(buf)
    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, function()
            require("java_lite.nav")[fn](vim.v.count1)
        end, { buffer = buf, silent = true, desc = "Java: " .. desc })
    end
    map("]f", "next_method", "下一个方法")
    map("[f", "prev_method", "上一个方法")
    map("<leader>o", "outline", "类/方法列表")

    -- 空格 d 统一查看定义 / 文档；浮窗里按 b 打开在线文档
    vim.keymap.set({ "n", "x" }, "<leader>d", function()
        require("java_lite.doc").show()
    end, { buffer = buf, silent = true, desc = "Java: 查看定义/文档" })
end

return M
