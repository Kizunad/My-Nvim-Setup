" java_lite 的高亮补充：nvim 保证 after/ 里的文件在自带的 syntax/java.vim 之后执行，
" 所以这里加的规则不会被 java.vim 开头的 `syntax clear` 清掉；也只在加载 Java 语法时才会运行
lua require("java_lite").highlight()
