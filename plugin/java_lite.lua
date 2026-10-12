-- java_lite：打开 Java 文件时才挂上“轻量高亮补充 + 方法跳转”，细节见 lua/java_lite/
--   高亮补充：after/syntax/java.vim 在 nvim 自带的 java 语法加载完之后调用 require("java_lite").highlight()
--   方法跳转：这里在 FileType java 时挂上缓冲区局部按键
-- 没打开过 Java 文件，就不会加载任何 java_lite 模块
vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("JavaLite", { clear = true }),
    pattern = "java",
    callback = function(args)
        require("java_lite").attach(args.buf)
    end,
})
