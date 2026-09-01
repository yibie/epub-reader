# Emacs 生态 EPUB 阅读方案调研

> 调研日期：2026-08-31。活跃度以官方仓库、包归档、最近提交和发布记录为准；体验判断来自实现方式、项目文档、问题追踪与可复现的功能边界，不把“仓库仍可安装”误写成“仍在积极维护”。

## 结论先行

Emacs 里的 EPUB 方案其实分成四条路线，彼此解决的不是同一个问题：

1. **要稳定、完整的电子书体验**：由 Emacs/CalibreDB 管书和启动，正文交给 Calibre E-book Viewer、Foliate 或 Thorium。这是目前最现实的默认选择。
2. **要留在 Emacs，并保留文本、Org 和键盘工作流**：继续用当前仍在维护的 `nov.el 0.5.0`，加 `shrface`、正确的 CJK visual-line 配置和 `org-remark`。它能明显改善阅读，但无法越过 `shr` 不是浏览器排版引擎这一上限。
3. **要在 Emacs 窗口里获得现代网页/Calibre 渲染**：新项目 `eaf-ebook-viewer` 最有潜力，但 EAF/Qt/Calibre 依赖很重，且截至本次调研仅诞生约三周；适合试用，不适合作为唯一可靠方案。`nov-xwidget` 次之。
4. **主要目的是精读、检索、摘录和写笔记**：用 Pandoc 把 EPUB 转成 Org，往往比修补阅读器更省时间；代价是放弃原书版式、分页和 EPUB 原生位置。

换言之，用户觉得 `nov.el` “非常难用”，若主要不满是字体、行宽、CJK 换行和标注，可以改良；若主要不满是 CSS、复杂排版、图片布局、分页和原生高亮，则应换渲染路线，而不是继续堆 `nov.el` 配置。

## 总览对比

活跃度标记：**活跃**＝近一年有实质提交；**新生**＝活跃但历史不足以判断稳定性；**低活跃**＝可用但近年维护稀少；**停滞**＝多年无维护。安装成本是相对 Emacs 用户而言。

| 方案 | 截至 2026-08-31 的状态 | 安装成本 | 排版/图片 | TOC、进度、书签 | 标注 | Emacs 原生文本 | 简评 |
|---|---|---:|---|---|---|---|---|
| `nov.el 0.5.0` | 活跃；旧 GitHub 仓库归档，但上游和 NonGNU ELPA 仍更新 | 低；libxml2 + unzip/bsdtar | 较弱；受 `shr` 上限约束 | TOC、上次位置、Emacs bookmark 有；全书百分比弱 | 核心无高亮笔记库 | 是 | 最轻、最 Emacs，但并非高保真阅读器 |
| `nov` + `shrface` + CJK 配置 + `org-remark` | 各主要组件活跃 | 低—中 | 比裸 `nov` 易读；仍不支持出版社 CSS | 沿用 `nov` | Org sidecar 高亮/批注，锚点为尽力恢复 | 是 | 原生 Emacs 路线的最佳组合 |
| `nov-xwidget` | 活跃度中等；最近实质提交 2025-01 | 高；需带 xwidget 的 Emacs/WebKitGTK | 好，接近浏览器 | 可用但位置同步/恢复仍有公开问题 | 浏览器页面内标注难与 Emacs overlay 整合 | 否 | 排版升级明显，构建和状态一致性是代价 |
| `nov-web` | 低活跃/实验；2025-01 一次性初版 | 低—中；`nov` + 外部浏览器 | 好，取决于浏览器 | 基础跳转；状态整合弱 | 可借浏览器扩展，但不回到 Emacs 数据 | 否 | 简单浏览器桥，适合临时用 |
| `eaf-ebook-viewer` | **新生**；2026-08-11 创建，08-30 仍密集提交 | 很高；EAF + Qt/Python + 编译 Calibre 运行时 | 很好；Calibre 原生渲染 | TOC、搜索、书签、CFI 位置较完整 | 已有高亮/笔记 | 否，但在 Emacs 窗口中 | 当前最有潜力，也最不成熟、最重 |
| EAF `eaf-pdf-viewer` 打开 EPUB | 活跃 | 高；EAF + PyQt6 + PyMuPDF | 页图像/页面式，版式稳定但不重排 | TOC、搜索、保存位置、进度 | 有 EAF/PyMuPDF 标注能力 | 否 | 现实可用，但本质是页面阅读，不是专门 EPUB 体验 |
| `emacs-webkit` + 自制/`nov-web` 适配 | 停滞；最后提交 2023-06 | 高；动态模块 + GTK/WebKitGTK | 浏览器级 | 要自行实现 EPUB 状态层 | 要自行实现 | 否 | 它是浏览器组件，不是 EPUB 阅读器 |
| `calibredb.el` | 活跃；2026-08 仍更新 | 中；Calibre + SQLite | 不渲染 | 擅长书库、元数据、筛选和启动 | 不负责正文标注 | 不适用 | 管书前端，不是 `nov` 的渲染替代品 |
| Pandoc：EPUB → Org/Markdown | Pandoc 活跃成熟 | 中；一次转换 | 语义文本好，原版式丢失；媒体可抽取 | 变成 Org 目录；无 EPUB 进度 | Org 全套标注/链接/笔记 | 是 | 精读、检索、摘录的高性价比路线 |
| 外部 Calibre/Foliate/Thorium | 都有现实维护；成熟度高 | 低—中；另装应用 | 最好 | 完整 | 完整，但数据通常在外部应用 | 否 | 综合体验第一，Emacs 只负责编目和启动 |
| 内置 DocView + MuPDF | Emacs 内置，活跃 | 低；需 `mutool` | 页图像，视觉稳定 | 页导航、outline；位置能力一般 | 很弱 | 否 | 最省事的保底方案 |
| `emacs-reader` | 活跃；2026-08-31 仍有提交 | 中—高；MuPDF + 编译动态模块 | 页图像，快速、稳定 | outline、bookmark、save-place | 当前缺完整文本高亮/笔记 | 否 | 有前景的原生窗口页图像阅读器 |
| `doc-tools` | 活跃但 WIP | 高；多后端手装，偏 GNU/Linux | 连续页图像、多栏、缩略图 | 依后端 | EPUB 标注能力有限 | 否 | 面向愿意折腾的实验路线 |
| `emacs-ereader` / `epubmode.el` | 停滞/历史项目 | 中 | 同样受 `shr` 或旧实现限制 | 基础 | 有零散旧功能 | 部分 | 不应作为 2026 年新装推荐 |

## 1. `nov.el`：它没有死，但渲染架构决定了上限

### 1.1 维护状态

网上最容易造成误判的是 [wasamasa/nov.el](https://github.com/wasamasa/nov.el) 已归档，最后活动停在 2020 年。项目实际上迁到了作者自己的 [depp.brause.cc 上游](https://depp.brause.cc/nov.el/)，[NonGNU ELPA](https://elpa.nongnu.org/nongnu/nov.html) 当前提供 `nov 0.5.0`；[emacs-pe/nov.el](https://github.com/emacs-pe/nov.el) 是同步镜像，2025-12 仍有字体 remap、相对路径等修复，NonGNU ELPA 的开发归档在 2026 年仍可见更新。因此准确结论是：

- **维护强度不高，但仍在维护**；
- 老问题追踪器仍有参考价值，却不能用“旧仓库归档”直接推导“项目死亡”；
- `0.5.0` 比许多旧博客所写版本已有 EPUB3 navigation TOC、Emacs bookmark、Org link 和跨 spine 的 multi-isearch 等改进。

`nov` 的安装负担仍很轻：带 libxml2 的 Emacs，加 `unzip` 或 `bsdtar`。这是它最大的结构性优势。

### 1.2 `shr` 渲染与排版

`nov` 解包 EPUB、解析 spine，再把每个 XHTML 文档交给 Emacs 的 `shr-render-region`。`shr` 的目标是把 HTML 化成 Emacs 文本和 face，不是实现浏览器的 CSS 盒模型。旧问题 [#45](https://github.com/wasamasa/nov.el/issues/45) 直指核心：除少数能力外，书内 CSS 不会像浏览器那样生效。于是常见后果包括：

- 出版社字体、段前段后、首行缩进、float、复杂表格、分栏、固定版式和纵排丢失或退化；
- 语法高亮、装饰性布局和交互脚本基本不能指望；
- `nov-text-width` 和 face 能把“纯文字书”调舒服，却不能恢复原书设计。

这不是换一个主题或增加几段 face 配置能彻底修好的问题。小说、技术书的正文通常还能读；教材、漫画、固定版式 EPUB、复杂脚注/表格则很容易难用。

### 1.3 CJK 换行和字体

中文阅读常见的坏体验来自两层：`shr` 生成的段落宽度，以及 Emacs visual-line 默认按空白寻找断点。Emacs 28 起的 `word-wrap-by-category` 会按字符类别换行，并配合 `kinsoku.el` 避免部分东亚标点出现在不合适的行首/行尾；见 [Emacs 28 NEWS](https://www.gnu.org/software/emacs/news/NEWS.28.html) 和 [Visual Line Mode 手册](https://www.gnu.org/software/emacs/manual/html_mono/emacs.html#Visual-Line-Mode)。对 `nov`，更合理的是让正文不做硬填充，再由窗口视觉折行：

```elisp
(with-eval-after-load 'nov
  (setq nov-text-width t))

(setq-default word-wrap-by-category t)
(require 'kinsoku)

(add-hook 'nov-mode-hook #'visual-line-mode)
;; 若已安装 visual-fill-column：
(add-hook 'nov-mode-hook #'visual-fill-column-mode)
```

再为 `nov-mode` 设置 `variable-pitch`、行距和 `visual-fill-column-width`，通常能修掉“行太宽、中文在怪位置断行”的大部分问题。它只改善 Emacs 的视觉折行，**不会**让 `shr` 突然支持完整 CSS、竖排或固定版式。历史字体缩放问题可参考 [#54](https://github.com/wasamasa/nov.el/issues/54) 和 [#70](https://github.com/wasamasa/nov.el/issues/70)；当前版已经修过部分 Emacs 29+ font remap 问题，但第三方 face 仍可能需要单独配置。

### 1.4 图片

当前 `nov` 能展示 Emacs `create-image` 支持的格式，并按窗口/`shr-max-image-proportion` 缩放；显示失败时尽量退回 alt 文本。现实边界仍包括：

- 依赖当前 Emacs 构建的图像库和图形显示环境；某些 WebP/SVG/异常 MIME 会失败；
- `width`/`height`、文字环绕和 CSS 布局不等同浏览器；
- SVG 内相对引用、复杂 SVG、图片型页面仍可能有问题；
- 大图与表格会受窗口宽度和重新渲染影响。

旧问题 [#50](https://github.com/wasamasa/nov.el/issues/50) 展示了“不支持格式或无图形能力时正文被图片错误打断”的典型失败。近年的 SVG workaround 改善了简单情形，不能把它等同于完整浏览器图像栈。

### 1.5 TOC、搜索、进度和书签

当前 `nov` 同时处理 EPUB2 NCX 与 EPUB3 navigation document，并提供 TOC、前后章节、history、Imenu 和跨文档 multi-isearch。它的 TOC 是另一个渲染缓冲区，不是现代阅读器的常驻侧栏；返回 TOC 后不一定保持“刚才那一项”的上下文，[旧问题 #19](https://github.com/wasamasa/nov.el/issues/19) 至今仍代表这种摩擦。

进度模型是“spine 文档序号 + 当前 buffer point”。`nov-save-place-file` 默认保存每本书的最后位置，Emacs 原生 bookmark 则可保存多个位置；Org link 也能编码文件、文档 index 和 point。这里有三个限制：

- 核心界面没有可靠的全书页数/百分比；旧请求 [#30](https://github.com/wasamasa/nov.el/issues/30) 正是这个缺口；
- 保存位置依赖 EPUB 的唯一 identifier；制作不规范的书可能恢复失败；
- point 是渲染后文本坐标，窗口宽度、表格重排、版本或内容变化会让外部标注锚点漂移。

因此 `nov` 的“继续读”够用，和 Readium/Calibre 的 CFI、分页与设备同步不是一个等级。

### 1.6 标注

`nov` 核心提供 Emacs bookmark 和 Org stored link，但没有完整的“选中文本 → 高亮 → 写旁注 → 导出/同步”数据库。现实补丁是：

- [`org-remark`](https://github.com/nobiot/org-remark)：最匹配 `nov` 的通用方案，把高亮和批注放在 Org sidecar；有专门的 `org-remark-nov-mode`。它会尽力处理 `nov` 重排后位置变化，但锚点仍不如 EPUB CFI 稳定。
- [`org-noter`](https://github.com/org-noter/org-noter)：适合一边读一边在独立 Org 文档中记章节/位置笔记；项目以 PDF 为首要目标，EPUB/nov 支持相对次要。
- [`paw`](https://github.com/chenyanming/paw)：SQLite 驱动的高亮、书签、词典、翻译、TTS 和语言学习工作流，功能丰富但依赖与配置也更多。
- [`nov2note.el`](https://github.com/lujun9972/nov2note.el)：把所选片段按 EPUB TOC 层级捕获到 Org，适合摘录型精读；是活跃但极小众的手工安装项目，不是通用高亮层。

综合看，**`nov + org-remark` 是一般标注的首选，`nov2note` 是结构化摘录的有趣补充**。

## 2. 现有替代与增强方案

### 2.1 `nov-xwidget`

[`nov-xwidget`](https://github.com/chenyanming/nov-xwidget) 复用 `nov` 的解包和目录逻辑，把内容交给 Emacs 内置 xwidget WebKit，因此 CSS、图片、字体和 CJK 排版明显比 `shr` 接近真实网页。项目支持自定义 CSS/JavaScript、明暗主题和尺寸调整，最近一批修复在 2025-01。

代价很具体：Emacs 必须编译带 xwidget，通常还需要 GTK/WebKitGTK；这对标准 macOS NS Emacs 尤其不友好。浏览内容生活在 WebKit widget 中，普通 Emacs point、overlay、isearch 和文本包不再天然工作。公开问题仍包括最后位置、href 后当前位置、直接打开和高亮/光标等状态整合问题。它适合“愿意维护特殊 Emacs 构建、最在乎网页排版”的用户，不能视作零成本替换。

### 2.2 EAF：历史上的“EPUB viewer”与新的 `eaf-ebook-viewer`

搜索中没有找到一个持续独立维护、正式名为 `eaf-epub-viewer` 的官方应用。实际存在两条 EAF 路线：

1. [`eaf-pdf-viewer`](https://github.com/emacs-eaf/eaf-pdf-viewer) 通过 PyMuPDF 支持 PDF，也能打开 EPUB。它有 TOC/TOC 搜索、全文搜索、进度提示、保存位置与标注相关命令，但整体是页面/图像式阅读体验，并非 EPUB 浏览器重排。
2. 2026-08-11 才发布的 [`eaf-ebook-viewer`](https://github.com/chenyanming/eaf-ebook-viewer) 嵌入 Calibre 8.7 的电子书渲染能力。截至 08-30 仍在快速修 CFI 导航、标注缓存、Linux 安装、TTS 和 resize；已经宣称支持 EPUB/MOBI/AZW3/FB2、TOC、搜索、书签、高亮/笔记、字体、翻页和 TTS。

第二条路线的体验上限最高，因为它不是拿 `shr` 模拟浏览器，而是直接借用成熟 Calibre renderer；同时它也是本表最重的方案之一：要安装 [EAF 核心](https://github.com/emacs-eaf/emacs-application-framework)、Python/Qt，拉取子模块，准备系统原生依赖并编译其 Calibre runtime。它还很年轻，尚无跨版本、跨平台的长期稳定记录。推荐态度是“**积极试用，保留外部阅读器兜底**”，不是立刻把书库和标注全部押上去。

### 2.3 `emacs-webkit`

[`emacs-webkit`](https://github.com/akirakyle/emacs-webkit) 是动态模块 WebKit 浏览器，定位类似 xwidget 的替代组件；它**不负责 EPUB 容器、spine、TOC、进度和标注**。要读 EPUB，仍需用 `nov`/脚本解包并为它写适配层，或配合 `nov-web`。构建依赖 GCC、pkg-config、GTK3、glib-networking 和 WebKitGTK，主要适合 GNU/Linux/GTK/pgtk；最后提交停在 2023-06，README 也坦言作者缺少维护时间。除非用户已经在用它，不建议为了 EPUB 单独采用。

### 2.4 `nov-web`

[`nov-web`](https://github.com/chenyanming/nov-web) 在 2025-01 发布：把 EPUB 内容提取、注入 CSS/JS，再用可配置的 `browse-url` 后端打开。它不要求定制 Emacs，能利用普通浏览器以及 Yomitan 一类浏览器扩展，视觉体验好于 `shr`。

项目规模很小，主要提交集中在创建当天；初版还存在一次只处理一个 EPUB/输出目录之类的限制，浏览器历史、书内位置、书签和标注也没有形成可靠的 Emacs 数据模型。适合把它看作“从 `nov` 快速跳到浏览器”的桥，不宜作为长期书库系统。

### 2.5 `shrface` 增强 `nov`

[`shrface`](https://github.com/chenyanming/shrface) 在 2026-08 仍活跃。它为 `shr`/EWW/`nov` 增加类似 Org 的标题、列表、段落和链接外观，以及 Imenu、outline 折叠、标题导航、`org-indent` 和导出 Org 等能力。对于结构清楚的非虚构书、技术书，这是很划算的改良。

要把预期放对：`shrface` 改善的是 `shr` 输出后的**语义外观和导航**，不是 CSS 引擎。它不能恢复 float、grid、固定版式、复杂字体和出版社分页。推荐与 visual-fill-column、CJK 换行和 `org-remark` 成套使用，而不是宣称它解决了 `nov` 的所有问题。

### 2.6 `calibredb.el`

[`calibredb.el`](https://github.com/chenyanming/calibredb.el) 是很成熟的 Emacs Calibre 书库前端，2026-08 仍活跃。它擅长 dashboard、元数据、标签、虚拟书库、搜索、收藏/归档、OPDS 和启动书籍；依赖 Calibre 与 SQLite。

它不渲染正文，所以不能单独替代 `nov`。正确组合是 `calibredb` 管理与检索，按书籍类型启动 `nov`、EAF 或外部 Calibre/Foliate/Thorium。小众扩展 [`calibredb-reading-tracking.el`](https://github.com/ginqi7/calibredb-reading-tracking.el) 在 2026 年加入 SQLite 阅读时长、当前/总页等记录，但仍需手工初始化和额外分页工具，且不是渲染器。

### 2.7 Pandoc 转 Org/Markdown

Pandoc 官方文档列出 EPUB 输入和 Org/Markdown 输出，并可抽取媒体；见 [Pandoc User's Guide](https://pandoc.org/MANUAL.html)。典型命令：

```sh
pandoc book.epub -f epub -t org \
  --extract-media=book-media \
  -o book.org
```

转换后得到真正的 Emacs 文本：中文换行、isearch/ripgrep、Org folding、链接、任务、批注、版本控制和全文知识库都非常自然。缺点同样明确：出版社 CSS、页码、EPUB CFI、固定版式、脚本和阅读进度消失；脚注、表格、数学公式与图片路径的保真度取决于原书。它最适合 DRM-free 的小说、论文集和技术书，尤其是“读的最终目的是做笔记”的用户。对漫画、固定版式和只想舒适翻页的人不合适。

### 2.8 外部阅读器集成

这是综合可靠性最高的路线：在 Dired、Embark 或 CalibreDB 中选书，用 `start-process` 启动外部应用。可选项包括：

- [Calibre E-book Viewer](https://manual.calibre-ebook.com/viewer.html)：跨平台，CSS/字体/分页、搜索、TOC、书签、高亮/笔记、TTS 完整，且天然配合 CalibreDB。
- [Foliate](https://github.com/johnfactotum/foliate)：Linux/GTK/WebKit 路线，界面轻、EPUB/Readium 体验好，适合桌面阅读。
- [Thorium Reader](https://github.com/edrlab/thorium-reader)：跨平台 Electron/Readium，重一些，但无障碍、格式兼容和注释能力成熟。
- macOS Books、KOReader 等系统/设备阅读器：若用户已有同步生态，往往比重新在 Emacs 造同步层可靠。

最小 Calibre 启动函数：

```elisp
(defun my-open-epub-in-calibre (file)
  (interactive "fEPUB: ")
  (start-process "ebook-viewer" nil
                 "ebook-viewer" (expand-file-name file)))
```

优点是排版、CJK、图片、TOC、全书进度和原生标注都最好；缺点是正文不再是 Emacs buffer，标注通常留在应用自己的数据库。现实折中是：外部阅读器负责连续阅读，重要摘录通过 Org capture/导出回到 Emacs。

## 3. 页图像路线与其他小众方案

### 3.1 内置 DocView + MuPDF

Emacs [Document View](https://www.gnu.org/software/emacs/manual/html_node/emacs/Document-View.html) 可借 `mutool` 把 EPUB 渲染成页面图像，支持页导航、缩放、切边、文本搜索视图和 outline/Imenu。它几乎不需要 Elisp 配置，版式、CJK 和图片也不会被 `shr` 重写。

缺点是初次转换和缓存可能慢，正文是图像，不适合普通选择、overlay、字体重排和 Org 式标注。它是“已经装 MuPDF，偶尔打开复杂 EPUB”的低成本保底，而不是现代电子书阅读器。

### 3.2 `emacs-reader`

[`emacs-reader`](https://codeberg.org/MonadicSheep/emacs-reader) 用 MuPDF 和 Emacs 动态模块做多格式页图像阅读，支持 EPUB/MOBI/FB2/XPS/CBZ 等；截至调研当天仍有提交。它有线程化渲染、缩放/适宽、outline/Imenu、Emacs bookmark 和 save-place，通常会比传统 DocView 的批量转换更流畅。

安装需要 MuPDF 1.26+、编译器和构建动态模块；当前实现的强项是看页面，不是文本工作流，尚缺完整的正文选择、全文文本高亮/批注等能力。适合重视“留在 Emacs 窗口 + 版式稳定 + 快速翻页”的用户。

### 3.3 `doc-tools`

[`doc-tools`](https://github.com/dalanicolai/doc-tools) 是仍在开发的通用文档图像查看框架，MuPDF 后端覆盖 EPUB，提供连续滚动、多栏和缩略图侧栏等思路。安装要手工组合多个仓库/后端，主要面向 GNU/Linux；项目文档也标注 WIP，缓存整本页图像可能占几十到数百 MB。PDF/DjVu 的某些搜索或标注能力不能自动推定对 EPUB 同样完整。它更像供 Emacs hacker 试验的未来方向。

### 3.4 `pqreader`

[`pqreader`](https://github.com/metaescape/pqreader) 是 PyQt6/PyMuPDF 的小型概念验证，可由 Emacs 外部进程打开电子书。项目体量与使用者都很小，能力又与 EAF PDF Viewer 重叠；除研究实现思路外，没有明显理由优先选它。

### 3.5 `nov2note.el`、`eldoc-mouse-nov`、`komga-sync.el`

- [`nov2note.el`](https://github.com/lujun9972/nov2note.el) 在 2026 年仍有 EPUB3 TOC 等更新，把选区按书籍目录捕获进 Org，是小而实用的摘录工具。
- [`eldoc-mouse-nov`](https://github.com/huangfeiyu/eldoc-mouse-nov) 为 `nov` 的内部链接/脚注增加鼠标悬停预览，已经进入 NonGNU ELPA；它改善脚注阅读，不改变渲染。
- [`komga-sync.el`](https://github.com/chmouel/komga-sync.el) 是 2026-07 才出现的 Komga Readium 进度同步实验，需要 Komga、curl 和较新 Emacs。由于 `nov` 的 raw XHTML point 与外部 renderer 百分比并不等价，只应把同步值当近似。

另一个反例是 [`librera-sync`](https://github.com/jumper047/librera-sync)：项目文档明确不支持 EPUB，原因正是百分比依赖具体 renderer。它说明“把 `nov` point 换算成任意外部阅读器进度”不是一个已经解决的通用问题。

### 3.6 历史包：`emacs-ereader` 与 `epubmode.el`

[`emacs-ereader`](https://github.com/bddean/emacs-ereader) 曾尝试把整本 EPUB 读入单 buffer，并做 Org link/边栏注释，但仓库明确称不再维护，最后活动在 2017 年；依赖和 `shr` 实现也比现代 `nov` 更旧。EmacsWiki 的 `epubmode.el` 更早，`nov` README 早已把它当作“不妨自己看看”的历史方案。两者可供考古，不应列入新用户安装清单。

### 3.7 终端阅读器作为 Emacs 子进程

如 [`baca`](https://github.com/wustho/baca) 这样的终端电子书阅读器可以跑在 vterm/term 内，键盘导航和纯文字体验不错，依赖比 GUI 引擎小。它仍不是 Emacs buffer，CSS、图片、复杂布局和标注能力也弱于成熟 GUI 阅读器；只适合纯文本小说和终端偏好者。

## 4. 初步排序

### 综合排序：面向“`nov.el` 难用，想真正改善阅读”

1. **CalibreDB/Dired + 外部 Calibre E-book Viewer、Foliate 或 Thorium**：最成熟、最少踩渲染坑；Emacs 管理，专业阅读器阅读。
2. **`nov 0.5.0` + `shrface` + visual-fill/CJK + `org-remark`**：最佳原生 Emacs 文本方案，尤其适合小说、技术书和 Org 工作流；必须接受 CSS 上限。
3. **Pandoc → Org**：精读、检索、摘录和长期知识库的首选；它是转换工作流，不是版式阅读器。
4. **`eaf-ebook-viewer`**：功能上最接近“Emacs 里的现代 EPUB 阅读器”，但依赖最重且项目太新；建议试点观察。
5. **`emacs-reader` / 内置 DocView + MuPDF**：复杂版式的可靠页图像路线；牺牲文本操作。
6. **`nov-xwidget`**：浏览器排版明显更好，但 xwidget 构建、平台可用性和 Emacs 状态整合限制了普适性。
7. **EAF PDF Viewer 打开 EPUB**：已有较成熟的 EAF 页面阅读能力，但若只为 EPUB 上 EAF，性价比不如新 ebook viewer 或外部 Calibre。
8. **`nov-web`**：轻量实验桥，长期进度、书库与标注状态不够完整。
9. **`emacs-webkit` 自制适配 / `doc-tools` / `pqreader`**：只推荐已有依赖或愿意参与开发的用户。
10. **`emacs-ereader` / `epubmode.el`**：不推荐新装。

### 按用户目标选

| 首要目标 | 首选 | 次选 | 不应抱有的期待 |
|---|---|---|---|
| 最舒服地把书读完 | 外部 Calibre/Foliate/Thorium | `eaf-ebook-viewer` | 让 `shr` 完整复刻出版社 CSS |
| 全程 Emacs、可搜索文本 | 改良后的 `nov` | Pandoc → Org | xwidget 页面仍像普通 Emacs buffer |
| 中文小说 | 改良 `nov`，启用按类别折行/禁则 | 外部阅读器 | 仅换主题就解决 CJK 断行 |
| 固定版式、图文教材 | 外部阅读器 | `emacs-reader`/DocView | `nov`/`shrface` 保真显示 |
| 高亮、旁注、知识库 | Pandoc → Org；或 `nov + org-remark` | 外部阅读器后导出摘录 | `nov` 核心自带稳定 CFI 标注 |
| 书库管理 | `calibredb.el` | Calibre GUI | CalibreDB 自己渲染正文 |
| 愿意重依赖、追求 Emacs 内现代 UI | `eaf-ebook-viewer` 试用 | `nov-xwidget` | 新生项目已有长期稳定性 |

## 5. 建议的落地路径

对一个已经被 `nov.el` 劝退的用户，不建议先花几天重写 face。更有效的两周试用顺序是：

1. 先用同一本“纯文字书”和一本“复杂图文书”建立对照。
2. 纯文字书试 `nov 0.5.0 + shrface + visual-fill-column + word-wrap-by-category + org-remark`；若阅读和标注够用，就保留这条原生工作流。
3. 复杂图文书直接交给 Calibre Viewer/Foliate/Thorium；用 CalibreDB 或 Dired 从 Emacs 启动。
4. 若“正文必须显示在 Emacs 窗口内”是硬要求，再试 `eaf-ebook-viewer`，同时保留外部阅读器和标注导出备份。
5. 对需要引用、检索、版本控制的重点书，单独跑 Pandoc 转 Org；不要把所有书都预转换。

这个组合避免了寻找一个并不存在的“轻依赖、浏览器级排版、Emacs 原生文本、完整标注同步、跨平台且成熟”的万能包。

## 主要来源

- `nov.el`：[NonGNU ELPA 包页](https://elpa.nongnu.org/nongnu/nov.html)、[现上游](https://depp.brause.cc/nov.el/)、[GitHub 镜像及源码](https://github.com/emacs-pe/nov.el)、[旧问题追踪器](https://github.com/wasamasa/nov.el/issues)
- Emacs CJK/视觉折行：[Emacs 28 NEWS](https://www.gnu.org/software/emacs/news/NEWS.28.html)、[Emacs Manual: Visual Line Mode](https://www.gnu.org/software/emacs/manual/html_mono/emacs.html#Visual-Line-Mode)
- 浏览器路线：[`nov-xwidget`](https://github.com/chenyanming/nov-xwidget)、[`nov-web`](https://github.com/chenyanming/nov-web)、[`emacs-webkit`](https://github.com/akirakyle/emacs-webkit)
- EAF 路线：[EAF](https://github.com/emacs-eaf/emacs-application-framework)、[`eaf-pdf-viewer`](https://github.com/emacs-eaf/eaf-pdf-viewer)、[`eaf-ebook-viewer`](https://github.com/chenyanming/eaf-ebook-viewer)
- 原生增强与笔记：[`shrface`](https://github.com/chenyanming/shrface)、[`org-remark`](https://github.com/nobiot/org-remark)、[`org-noter`](https://github.com/org-noter/org-noter)、[`paw`](https://github.com/chenyanming/paw)、[`nov2note.el`](https://github.com/lujun9972/nov2note.el)
- 管理和转换：[`calibredb.el`](https://github.com/chenyanming/calibredb.el)、[Pandoc User's Guide](https://pandoc.org/MANUAL.html)
- 页图像/小众路线：[Emacs Document View](https://www.gnu.org/software/emacs/manual/html_node/emacs/Document-View.html)、[`emacs-reader`](https://codeberg.org/MonadicSheep/emacs-reader)、[`doc-tools`](https://github.com/dalanicolai/doc-tools)、[`emacs-ereader`](https://github.com/bddean/emacs-ereader)
- 外部阅读器：[Calibre E-book Viewer](https://manual.calibre-ebook.com/viewer.html)、[Foliate](https://github.com/johnfactotum/foliate)、[Thorium Reader](https://github.com/edrlab/thorium-reader)

