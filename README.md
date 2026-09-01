# epub-reader

`epub-reader` 是一个基于 TextUI 布局层的原生 Emacs EPUB
阅读器。它直接解析 EPUB 的 OCF、OPF、spine 与目录文档，把 XHTML 转成语义块，再由
TextUI 按窗口宽度排版；除 TextUI 和系统归档命令外不引入重型依赖。

与 nov.el 的差异可以概括为一句话：nov.el 以 `shr` 显示整章 HTML，而本项目以自有 EPUB
模型、稳定 locator 和 TextUI 的宽度感知 frame/分块 viewport 组织阅读体验。逐项对比见
[与 nov.el 的比较](#与-novel-的比较)。

当前版本为 0.1.0，面向无 DRM、可重排（reflowable）的 EPUB 2/3。

## 安装

要求：

- Emacs 29.1 或更高版本；
- TextUI 0.5.1，当前以本地 checkout 加入 `load-path`；
- `unzip` 或 `bsdtar`，安装任意一个即可。两者都存在时默认先尝试 `unzip`。

把 TextUI 与本项目目录加入 `load-path`：

```elisp
(add-to-list 'load-path "/path/to/textui")
(add-to-list 'load-path "/path/to/epub-reader")
(require 'epub-reader)
```

例如本仓库开发环境使用：

```elisp
(add-to-list 'load-path "/Users/chenyibin/Documents/emacs/package/textui")
(add-to-list 'load-path "/Users/chenyibin/Documents/emacs/package/epub-reader")
(require 'epub-reader)
```

如果 Emacs 找不到归档命令，请先确认 `(executable-find "unzip")` 或
`(executable-find "bsdtar")` 返回非 `nil`。

## 快速上手

运行：

```text
M-x epub-reader-open RET /path/to/book.epub RET
```

阅读 buffer 会显示居中的正文栏；调整窗口宽度时，TextUI 会重新排版并尽量保持当前语义位置。
默认启用进度保存，sidecar 写在 EPUB 旁边的 `BOOK.epub.epub-reader`。可通过
`epub-reader-store-directory` 改到集中目录。

### 阅读键位

| 键        | 动作                                  |
|-----------|---------------------------------------|
| n / ] | 下一 spine 章节                       |
| p /  | 上一 spine 章节                       |
| SPC     | 向后翻页；到章尾时自动进入下一章      |
| S-SPC   | 向前翻页；到章首时进入上一章末尾      |
| b / f | locator 导航历史后退 / 前进           |
| t       | 打开层级目录 buffer                   |
| g       | 用 completing-read 按目录标题跳转   |
| RET     | 打开 point 所在的内部或允许的外部链接 |
| q       | 保存进度并关闭阅读 buffer             |

目录 buffer 中，`RET` 跳转（无目标的分组则折叠/展开），`TAB` 折叠/展开当前分组，`q`
隐藏目录。目录重开后会恢复先前选中的行。

## Customize

运行 `M-x customize-group RET epub-reader RET` 查看全部选项和 faces。常用项如下：

| 用途             | 变量                                                                                                                                                                                                                                                                                                                                                                |
|------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 正文与图片       | epub-reader-reading-width、epub-reader-image-rows、epub-reader-text-wrap-strategy                                                                                                                                                                                                                                                                                   |
| 交互首绘         | epub-reader-first-paint-max-blocks、epub-reader-first-paint-max-characters                                                                                                                                                                                                                                                                                          |
| 冷滚动 chunk     | epub-reader-scroll-chunk-max-blocks、epub-reader-scroll-chunk-max-characters                                                                                                                                                                                                                                                                                        |
| 后台预取         | epub-reader-background-idle-delay                                                                                                                                                                                                                                                                                                                                   |
| 长章 viewport    | epub-reader-chunk-max-blocks、epub-reader-chunk-max-characters、epub-reader-chunk-guard-blocks、epub-reader-chunk-overscan-screens                                                                                                                                                                                                                                  |
| 进度保存         | epub-reader-enable-progress、epub-reader-save-idle-delay、epub-reader-store-directory                                                                                                                                                                                                                                                                               |
| store 锁         | epub-reader-store-lock-timeout、epub-reader-store-ownerless-lock-grace                                                                                                                                                                                                                                                                                              |
| 链接策略         | epub-reader-external-link-schemes，默认只允许 http、https、mailto                                                                                                                                                                                                                                                                                                   |
| locator 降级范围 | epub-reader-locator-max-synthetic-distance、epub-reader-locator-max-synthetic-rows                                                                                                                                                                                                                                                                                  |
| 归档 adapter     | epub-reader-container-adapters                                                                                                                                                                                                                                                                                                                                      |
| 归档安全上限     | epub-reader-container-max-entries、epub-reader-container-max-files、epub-reader-container-max-directories、epub-reader-container-max-central-directory-bytes、epub-reader-container-max-path-bytes、epub-reader-container-max-entry-bytes、epub-reader-container-max-total-bytes、epub-reader-container-max-compression-ratio、epub-reader-container-member-timeout |

正文、标题、强调、引用、代码、链接、图片提示、header/footer 和目录状态均有
`epub-reader-*` face，可通过 `M-x customize-face` 调整。

## 功能矩阵

| 状态   | 能力                  | 0.1.0 行为                                                                                                                                                                                                                 |
|--------|-----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 已支持 | EPUB 容器与出版物模型 | 打开无 DRM 的 reflowable EPUB 2/3；中央目录安全 preflight 后按需解压 metadata、当前 spine 与当前 chunk 图片；解析 EPUB 2 NCX 与 EPUB 3 nav                                                                                 |
| 已支持 | 常见 XHTML 语义       | 段落、标题、强调、链接、引用、代码、无序/有序列表、简单表格的文本降级、异步后到图片与可见错误提示                                                                                                                          |
| 已支持 | CJK 与宽度重排        | TextUI 宽度感知折行、common kinsoku 与非末行两端对齐；默认 greedy 线性选断点，亦可选 balanced KP；窗口宽度、主题、字体或 text scale 变化时失效旧布局，并通过 focus/source anchor 保持位置；图片行预算跟随 remap 后字体高度 |
| 已支持 | 长章节                | 首绘/冷滚动小 chunk、block 数与字符数双软预算、guard/overscan、章节 region refresh；idle 扩展 viewport 并预取下一章，不会为整章预先生成 TextUI leaf/source property                                                        |
| 已支持 | 导航                  | 前后章、章尾自动前进、内部 fragment、外部链接 allowlist、history back/forward、层级/可折叠 TOC、标题补全跳转                                                                                                               |
| 已支持 | 进度                  | 基于书籍 fingerprint 的版本化 locator；位置变化后 idle debounce、换章与关闭保存；原子 merge/write；exact/degraded 恢复提示；全书加权百分比                                                                                 |
| 已支持 | 输入安全              | OCF 路径规范化与冲突检查、归档成员/大小/压缩比限制、逐成员流式提取、远程资源隔离、外链 scheme allowlist                                                                                                                    |
| 不支持 | 标注                  | 高亮、笔记、annotation UI、org-remark 集成                                                                                                                                                                                 |
| 不支持 | 受限或固定版式出版物  | DRM、fixed-layout、竖排与精确分页                                                                                                                                                                                          |
| 不支持 | 富媒体与复杂排版      | 复杂 ruby、MathML、SVG、音视频、JavaScript、通用 CSS、publisher font、float/grid fidelity                                                                                                                                  |
| 不支持 | 全书服务              | 索引式全文搜索、跨设备同步、EPUB CFI 或 Web Annotation 互操作                                                                                                                                                              |
| 不支持 | 纯 Elisp ZIP          | 0.1.0 仍通过 unzip/bsdtar adapter 流式读取归档                                                                                                                                                                             |

## 已知限制

- 极长的单个段落（几万字不分段的那种）会一次性载入渲染，翻到这种段落时可能出现一次
  明显的停顿。
- 极端内容可能出现行尾被截断而不是换行：比如一条特别长且中间没有任何可断点的
  URL，或个别特别宽的字形。正常文字不受影响。
- header 里的全书百分比是按各章文件大小估算的近似值，不是精确的字数比例；读到书末
  会到 100%，但中途的数值只当参考。
- 阅读进度文件（sidecar）的多开保护只在本地磁盘上可靠。如果把书和进度文件放在网盘
  或同步盘上、并且多台机器同时读同一本书，进度可能互相覆盖，保存也可能要等几秒锁
  超时。单机使用不受影响。
- Emacs 崩溃或被强杀后，进度目录里可能留下残余的锁文件或临时目录。目前不会自动清
  理，后续保存会自动等待并重试；如果发现保存一直变慢，手动删掉进度目录里陈旧的
  `*.lock` 类残留即可。

## 开发

测试脚本会重建最小 EPUB2/3、CJK、长章和 adversarial fixtures，然后用 `emacs -Q --batch`
运行全部 ERT：

```sh
./test/run-tests.sh
```

TextUI 不在默认开发路径时：

```sh
TEXTUI_DIR=/path/to/textui ./test/run-tests.sh
```

也可以用 `EMACS=/path/to/emacs` 指定 Emacs。生产模块应保持只调用 TextUI 公开 API；修改后至少
运行全量 ERT、byte-compile，并用一本文本型 EPUB 做只读 smoke test。

