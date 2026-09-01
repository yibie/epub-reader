# 从“为什么 nov.el 难用”出发的 EPUB 阅读器方案分析

> 状态：方案设计；日期：2026-08-31
>
> 目标：做一个以长时间阅读、中文排版、可靠进度和本地注释为核心的 Emacs EPUB 阅读器。这里讨论的是无 DRM、可重排（reflowable）的 EPUB 2/3；固定版式 EPUB 是另一个产品。

## 结论先行

推荐 **路线 B：新写一个“出版物模型 + 语义渲染器 + 稳定位置模型”的纯 Emacs Lisp 包**，最低支持 Emacs 29.1，不依赖第三方运行时包或外部阅读器。

关键不是再写一个通用 HTML/CSS 引擎，而是把范围收窄成“适合书籍的 Emacs 原生排版”：只支持常见的结构语义，用户阅读主题优先于出版社 CSS，不在正文中插入随窗口宽度变化的硬换行，并且从第一天就让进度和注释引用稳定的 EPUB 位置，而不是渲染后 buffer 的整数 point。

路线 A 适合用 1～2 周验证字号、行宽、CJK 换行和 TOC 交互，但不宜作为长期基础；路线 C 只有在“尽量复现浏览器排版”比 Emacs 原生体验、可移植性和轻依赖更重要时才应选择。

## 一、问题不是一个，而是四层错配

nov.el 本质上是一层很薄的适配：解包 EPUB，解析 OPF/NCX/nav 得到 spine，把当前 XHTML 交给 `shr`，再用 `(spine-index, buffer-point)` 表示阅读位置。它完成了“能打开”，但没有形成完整的阅读器领域模型。

```text
EPUB 文件
  -> nov：解包、manifest/spine/TOC
  -> shr：XHTML DOM 变成带 text properties 的普通 Emacs buffer
  -> nov：以章节序号和 point 做导航、历史与进度
```

“难用”来自四层问题叠加：

1. **媒介错配**：`shr` 是 Simple HTML Renderer，主要目标是把 HTML 内容变成可读 buffer，不是实现浏览器 CSS 排版。
2. **适配层过薄**：nov.el 没有补上居中阅读栏、动态重排、专用 TOC、全书位置等阅读器交互。
3. **领域模型缺失**：章节、语义节点、稳定 locator、选区、注释和书籍级进度没有统一模型。
4. **维护风险**：上游仓库已归档，版本为 0.3.0，最后提交停在 2020-05-06。继续依赖它等于由下游承担新 Emacs、EPUB 边界情况及兼容层的维护。

下面用三种归因标签：

- **SHR 固有限制**：保持“HTML -> 普通 buffer”及其有限 CSS 语义的前提下，不能靠 nov 的几个变量根治。
- **nov 实现问题**：EPUB 适配、状态或 UI 的选择，可以在不替换 SHR 的情况下改进。
- **Emacs 显示边界**：即使不用 SHR，普通 buffer 也不是浏览器盒模型；自定义渲染只能把它优化成优秀的“书籍排版”，不能获得完整 Web fidelity。

## 二、难用的具体根因

### 2.1 排版与渲染

| 症状 | 实际机制 | 主要归因 | 能否在 nov 上缓解 |
|---|---|---|---|
| 行宽不好控制，窗口变化后版面不自然 | SHR 通常在渲染时按 `shr-width` 计算宽度并向 buffer 插入换行；`nov-text-width` 只把这个宽度暴露出来。它不是“居中、随窗口动态变化的阅读栏”。字号或窗口变化后，旧换行不会自动成为新布局 | SHR 的一次性填充模型 + nov 缺少窗口布局层 | 可以。禁用 SHR 填充，改用视觉换行和窗口 margins；但须处理旧 Emacs、表格、图片与 resize 钩子 |
| 窄栏不能自然居中，左右留白不稳定 | CSS 的 `max-width: …; margin: auto` 没有普通 buffer 的等价盒模型；`shr-width` 控制内容填充宽度，不负责给窗口设置对称边距 | SHR/Emacs 显示边界；nov 未实现阅读栏 | 可以较好缓解：窗口局部 margins 或 `visual-fill-column` 类方案 |
| 左右对齐、两端对齐、首行缩进不可靠 | SHR 只识别很小的样式子集，忽略出版社 CSS 中常见的 `text-align`、`text-indent`、`line-height`、margin/padding 等；普通 buffer 也没有完整段落排版器 | 主要是 SHR 固有限制 | 只能实现统一的用户偏好。可为 `p`/标题自定义 handler；不能兼容任意 EPUB CSS |
| 中英混排或纯中文断行别扭，标点出现在不合适的位置 | 问题不在“Emacs 不支持中文”，而在 SHR 把重排结果固化成换行，又不实现 CSS `line-break`/`word-break`/`overflow-wrap` 规则。不同 Emacs 版本的 SHR 算法也不同。旧版本在可变宽字体、CJK/Latin 混排下尤其容易出问题 | SHR 的硬填充和 CSS 缺口；nov 未启用更合适的 CJK 视觉换行 | 可以明显缓解：禁用 SHR 填充，启用 `visual-line-mode`、`word-wrap-by-category` 和 `kinsoku`。这仍不是完整的 CSS 东亚排版 |
| 段落太松或太挤，章节标题和正文节奏单一 | SHR 的 `p` 基本上只是保证段前段后的 paragraph/newline；它不解释 EPUB 样式表里的段间距、行高和首行缩进 | SHR 固有限制；nov 没有用户排版 profile | 可以做“全书统一风格”，但难以忠实复原每本书的 CSS |
| 字体、字号、颜色和强调层级不统一 | SHR 以 face 表达有限的 HTML 语义，只处理很少的 inline style；nov 只有 `nov-variable-pitch` 这样的粗粒度开关 | 主要是 SHR；nov 配置面过小 | `shrface` 和自定义 face 很适合改善标题、链接、代码、引用，但不能增加盒模型 |
| 图片过大、过小、缩放后不重排，漫画/全页图体验差 | 新版 SHR 已有按窗口比例缩小、图片缩放和长图切片等能力，但 nov 对本地图片绕过 SHR，使用自己的 `nov-insert-image`；这段实现来自 2020 年，能力依赖旧 ImageMagick 分支，窗口 resize 后也不会自动重算 | nov 的本地图片覆盖是主要问题；缩放、环绕、浮动和图文布局仍受普通 buffer 限制 | 可以重写图片 handler，支持 fit-width/original 切换和 resize 后重渲染；做不到浏览器式浮动和复杂 CSS 图文布局 |
| 表格、脚注、ruby、SVG/MathML、竖排表现不确定 | SHR 只对部分标签做专门处理，未知标签通常只递归插入文本；复杂 CSS、writing mode 和脚本不在其目标内 | SHR 固有限制 | 只能逐项写 handler；继续增加时会逐渐变成另一套渲染器 |

一个重要判断是：**CJK 并不是必须换浏览器才能解决。** Emacs 的视觉换行支持按字符类别断行；加载 `kinsoku` 后还能避免常见标点出现在行首/行尾。nov.el 的问题是默认沿用了 SHR 的渲染时填充，没有把这套能力组织成阅读 profile。路线 A 和 B 都能改善 CJK；只有竖排、复杂 ruby、出版社 CSS 的精确复现才明显需要浏览器引擎。

### 2.2 导航和 TOC 交互

nov.el 已支持上一/下一 spine 文档、内部链接、前后历史、Org link、bookmark 和 Imenu。这些功能并非不存在，但组合起来仍像“浏览一组 HTML 文件”，而不是读一本书。

| 症状 | 根因 | 归因 |
|---|---|---|
| `t` 打开 TOC 后像进入另一个章节，正文被替换 | `nov-goto-toc` 找到 TOC 对应文档，再走普通 `nov-goto-document` 和 SHR 渲染；没有独立 TOC 视图 | nov 实现问题 |
| 大目录难浏览、层级不突出、缺少折叠和当前章节定位 | TOC 的主要 UI 是渲染后的 `<ol>/<a>`；没有 tree/outline 状态、当前节点高亮、breadcrumb 和专用快捷键 | nov 实现问题；SHR 的列表显示加重了问题 |
| 再次进入 TOC 回到开头 | TOC point 没有独立状态；上游 issue #19 至今仍是 open | nov 实现问题 |
| 跳章可用，但“跳到任意标题”不够显眼 | 后期增加了 Imenu 索引，但没有把 completion、TOC buffer 和正文上下文组织成一个发现性强的入口 | nov 产品/UI 问题 |
| 全书搜索、搜索结果上下文、从结果返回阅读位置不自然 | 正文 buffer 一次只包含一个 spine item，普通 `isearch` 天然只搜当前章节；nov 没有全书文本索引 | nov 架构问题，不是 SHR 必然限制 |
| 页/章/全书进度概念混在一起 | “页面”是窗口大小和字号的函数，spine item 长度又极不均匀；仅以当前 buffer 的位置或章节序号无法给出稳定的全书进度 | nov 缺少出版物级位置模型 |

### 2.3 进度保存不等于可靠恢复

nov.el 确实有进度保存，不能简单归类为“缺失”。当前实现把书的 unique identifier 映射到：

```elisp
((index . SPINE-INDEX)
 (point . BUFFER-POINT))
```

并在清理 EPUB buffer 时写入 `nov-places`。问题在于这个坐标依赖渲染结果：

- 修改字号、行宽、渲染 handler、Emacs/SHR 版本后，同一个 `point` 可能指向另一段文字或超出范围。
- 只在 buffer 清理/退出路径保存，崩溃或强制终止会丢失本次阅读进度；也没有 idle debounce 的周期保存。
- EPUB unique identifier 可能缺失、错误或在不同文件中重复；只靠它作为主键会冲突。
- 多个 buffer 以“读全部旧状态 -> 写全部新状态”的方式更新同一文件，存在覆盖彼此新状态的风险。
- 没有格式版本、迁移、原子更新策略、最后阅读时间和多位置/bookmark 区分。
- `spine-index` 对书籍小改版不稳定；章节数百分比也会被长短不一的章节严重扭曲。

这些主要是 **nov 的状态模型问题**，不是 SHR 必然做不到。SHR 的影响在于它把 DOM 扁平化以后没有保留足够的 source mapping，使后补稳定 locator 比从渲染器设计之初加入更麻烦。

更可靠的位置至少应包含：

```text
book-key
  = 文件指纹 + EPUB identifier（identifier 只是提示，不是唯一真相）

locator
  = spine href
  + element id（若有）或 DOM path/语义块序号
  + 块内字符偏移
  + 归一化 text quote 与前后文（结构变化时做回退定位）
```

全书百分比应按各 spine item 的归一化可读文本长度加权，而不是按章节数平均。

### 2.4 注释和高亮缺失

nov.el 没有 annotation/highlight 数据模型、命令、持久化或列表 UI。临时 overlay 很容易做，可靠注释很难做：每次换章或 `g` 重渲染都会 `erase-buffer`，overlay 随之消失；即使记下 point，排版改变以后也不能稳定回放。

这里要区分两个责任：

- **功能缺失属于 nov**：选择文本、加高亮/笔记、浏览注释、跳转、删除和导出都应由阅读器实现。
- **实现难度部分来自 SHR**：SHR 输出没有面向 EPUB 的 source range/DOM locator。可以通过标签 handler 在文本上附加源节点属性来补，但这会侵入渲染过程。

所以注释不能作为最后才加的 UI 功能。无论选哪条长期路线，第一版的数据模型都应先定义 `book-key`、`locator`、`range`、`quote/context` 和 schema version。

## 三、候选路线

以下工程量按“一位熟悉 Emacs Lisp 的开发者、需要 ERT 测试、支持无 DRM 的 EPUB 2/3 reflowable、做到可发布 MVP”估算。它们是数量级，不是排期承诺。

### A. 基于 nov.el 增强：advice + shrface + 自定义排版

#### 做法

1. 保留 nov 的 EPUB 解包、OPF/spine/TOC 和链接处理。
2. 优先用已有扩展点 `nov-render-html-function`、`nov-pre-html-render-hook`、`nov-post-html-render-hook` 和 `nov-shr-rendering-functions`；只有无公开 seam 时才加 namespaced advice。
3. 用 `shrface` 改善标题、链接、列表、引用、代码 face；为 `p`、标题、脚注和图片写少量 tag handler。
4. 令 `nov-text-width` 禁用 SHR 硬填充，正文用 `visual-line-mode` + `word-wrap-by-category` + `kinsoku`；窗口局部 margins 提供居中的阅读栏，`line-spacing` 和 face 提供用户主题。
5. 把 TOC 做成单独的 outline buffer，并以 Imenu/completing-read 提供快速跳转。
6. 重写本地图片 handler；增加窗口 resize 后的延迟重算和 fit/original 切换。
7. 进度和高亮先用 sidecar；锚点至少保存 spine href + text quote，不能继续只存 point。

#### 评价

- **工程量**：视觉改善原型约 3～7 人日；含独立 TOC、可靠一些的进度和基础高亮的 MVP 约 3～6 人周。若要求跨排版稳定的注释，最终会侵入 nov/SHR，工程量迅速接近路线 B。
- **可维护性**：中低。上游已归档；advice 绑定函数名和内部行为；SHR 在新 Emacs 中仍会变化。可以通过“优先公开 hook、advice 集中在一个 compat 文件、按 Emacs 版本测试”把风险限制住。
- **阅读体验上限**：中。纯文本小说、技术书的正文能从“能看”提升到“舒服”；复杂表格、ruby、竖排、固定版式和出版社 CSS 仍差。
- **CJK 友好度**：中高（采用动态视觉换行后），但不支持完整 CSS 东亚排版。
- **主要风险**：补丁堆积、shrface 与 nov 自定义 tag handler 冲突、全局 advice 污染其他 SHR 用户、重渲染让 locator/overlay 失效、旧 nov 的 EPUB 兼容 bug 继续存在。

#### 适用条件与停止线

适合个人配置、快速获得改观、验证具体阅读 profile。若出现以下任一情况，应停止继续堆补丁并转路线 B：

- 需要给渲染文本保留 DOM/source range；
- 需要注释跨字号、窗口和渲染器版本稳定；
- 为了 TOC/进度又维护一份并行 spine/manifest 模型；
- 对 `nov-render-document`、`nov-visit-relative-file` 等核心路径出现多处 advice。

### B. 全新包：自行解析 EPUB，用书籍专用的 Emacs 渲染器

#### 核心设计

```text
ZIP/container
  -> Publication（metadata / manifest / spine / TOC）
  -> Section DOM（按章懒加载）
  -> Semantic Renderer（DOM -> 文本 + face + source properties）
  -> Reader UI（正文 / TOC / history / search）

Locator + Store 横跨 Publication、Renderer 和 UI：
  progress / bookmark / highlight / note 都引用同一种稳定位置
```

建议拆成六个深模块，避免 UI 直接依赖 ZIP 路径或 buffer point：

| 模块 | 职责 | 对外接口示例 |
|---|---|---|
| container | 读取 ZIP central directory，按需取成员，检查路径与解压上限 | `open`, `members`, `read-member`, `close` |
| publication | 解析 `container.xml`、OPF、manifest、spine、EPUB2 NCX / EPUB3 nav，统一相对 URL | `metadata`, `spine`, `toc`, `resolve-href` |
| renderer | 遍历 XHTML DOM，输出普通 buffer；保留 `epub-node`、source range、link、image 等 text properties | `render-section`, `rerender`, `source-at-point` |
| locator | buffer position 与稳定 EPUB locator 双向转换；按 id/path/quote 分级恢复 | `at-point`, `resolve`, `compare`, `progress` |
| store | 版本化、原子保存进度/bookmark/annotation，合并多个打开 buffer 的更新 | `load-book`, `put-progress`, `put-annotation`, `flush` |
| reader UI | mode、TOC tree、completion、历史、阅读主题、图片命令 | 用户命令，不暴露底层 DOM 细节 |

“自定义渲染”应是**语义白名单**，不是 CSS 引擎：

- 支持 `p`、`h1..h6`、`em/strong`、`blockquote`、`ul/ol/li`、`pre/code`、`a`、`hr`、`br`、`img/figure/figcaption` 和简单 table fallback。
- 正文每段保留为逻辑行，不因当前窗口宽度插入硬换行；用视觉换行动态重排。
- 用户 profile 统一控制 variable/fixed pitch、字号、阅读栏宽度、对称边距、行距、段距和主题。出版社 CSS 默认不主导布局。
- CJK profile 开启 `word-wrap-by-category` 和 `kinsoku`；默认左对齐，不在 MVP 做伪劣的两端对齐。
- 每个语义块和文本 range 都附带源节点信息，因此 rerender 后能重新解析 progress/highlight。
- 图片按需解出到受控 cache，默认 fit-width，支持 original/fit 切换；窗口 resize 只延迟更新图片和 margins，不重写持久位置。

“纯 Emacs Lisp、无重依赖”建议定义为：发布包只有 Emacs 内置依赖，不调用 Python、Node、Pandoc、Qt 或外部阅读器。XML 优先使用 Emacs 内建 libxml，缺少 libxml 时可对规范 XHTML 使用内建 `xml.el` fallback。ZIP 层需自己解析 central directory，并利用 Emacs 内建 zlib 能力处理常见的 store/deflate；这是路线 B 最先要做的技术 spike。

ZIP 不是简单的 `unzip` 包装。实现时必须把安全边界列为验收条件：拒绝绝对路径和 `..` 跳出、限制单成员/总解压大小与压缩比、校验 CRC/size、禁止默认网络加载远程资源、绝不执行 EPUB 内脚本。否则“无外部依赖”会换来 zip-slip 或 zip bomb 风险。

#### 评价

- **工程量**：可发布 MVP 约 8～12 人周；覆盖大量真实世界 EPUB、完善可访问性和兼容性约 4～6 人月。ZIP、URL 规范化、坏书容错和 locator 恢复比视觉样式更费工。
- **可维护性**：中高，前提是坚持语义白名单和深模块边界。零第三方运行时减少安装问题；但 EPUB 兼容矩阵、ZIP 安全和渲染器都由项目自己负责。
- **阅读体验上限**：对 reflowable 小说/技术书为中高，且 Emacs 原生键盘、搜索、选择和 Org 集成最好；对复杂 CSS、固定版式、竖排、脚本内容仍低于浏览器。
- **CJK 友好度**：高。可以从数据模型和视觉换行层原生考虑 CJK，而不是在硬填充之后修补；但不承诺浏览器级竖排/ruby/fidelity。
- **主要风险**：范围膨胀成 HTML/CSS 引擎；纯 EL ZIP 兼容和性能；不规范 EPUB 的长尾；稳定 locator 算法；图片和大章节的内存/延迟。

#### 控制风险的原则

- 最低支持 Emacs 29.1，避免为过旧显示 API 维护大量兼容分支。
- 只做 reflowable；遇到 `rendition:layout-pre-paginated` 明确提示“不支持”，不做半成品。
- 出版社 CSS 仅取少量安全语义提示，不承诺 fidelity。
- 按 spine item 懒解析、懒渲染；缓存键包含书籍指纹、href 和 renderer schema version。
- 所有位置功能只依赖 locator；buffer point 是瞬时投影，不进入持久化协议。
- 建立真实 EPUB fixture corpus，而不只测试手写的“完美 EPUB”。

### C. 借助外部渲染：xwidget-webkit / EAF / 转 Org

这其实是三个产品方向，不能把它们当作同一种后端随意替换。

#### C1. xwidget-webkit

解包 EPUB 后在 WebKit xwidget 中加载章节，注入 reader CSS；用 JavaScript DOM Range/selector 保存高亮，通过 Emacs ↔ JS 桥接导航和 sidecar。

- **工程量**：原型 1～2 人周；含安全、稳定 locator、TOC、键盘/焦点和持久化的 MVP 约 4～8 人周。
- **可维护性**：中低。依赖 Emacs 构建时具备 xwidget/WebKit，平台和发行版可用性不一致；JS 桥、WebKit 行为和 Emacs xwidget API 都是兼容面。
- **阅读体验上限**：最高，能利用 CSS、字体、ruby、SVG 和浏览器布局；固定版式也最有希望。
- **CJK 友好度**：高，现代 WebKit 的东亚排版明显优于 SHR。
- **风险**：焦点和 keymap 像“Emacs 里嵌了浏览器”；选择、isearch、复制、输入法和可访问性不再天然是 buffer 行为；测试困难。必须禁用 JS 或采用严格 sandbox，并阻止书籍发起网络请求。

#### C2. EAF

借助 EAF 的 Python/Qt/WebEngine 栈提供浏览器阅读视图，再与 Emacs 通信。

- **工程量**：已有 EAF 环境下集成约 3～6 人周；跨平台安装、发布和故障排查的长期成本更高。
- **可维护性**：低到中。项目本身代码可能少，但 Python、Qt、WebEngine、EAF、窗口系统和 IPC 共同构成依赖矩阵。
- **阅读体验上限**：与浏览器接近，适合重 CSS、漫画或固定版式。
- **CJK 友好度**：高。
- **风险**：安装重量最大，进程/窗口/焦点问题最多，不符合“下载一个 Elisp 包即可读”的目标；用户群被 EAF 环境限制。

#### C3. 转 Org 后用 org-mode 阅读

导入时把 XHTML 转成 Org，缓存每章或整书，然后复用 Org 的 outline、链接、搜索、折叠、标记和笔记生态。

- **工程量**：只做常见标签的导入器约 2～4 人周；处理图片、脚注、内部链接、缓存失效和 round-trip 的 MVP 约 1～2 人月。若依赖 Pandoc，开发更快但增加外部依赖和版本差异。
- **可维护性**：中。Org UI 很稳定，但“原 EPUB ↔ 转换后 Org”的映射、缓存 schema 和转换长尾要持续维护。
- **阅读体验上限**：对纯文本和学习型阅读为中高，对视觉 fidelity 为低到中。它更像“把书导入知识库”，不是忠实 EPUB 阅读器。
- **CJK 友好度**：中高，可沿用 Emacs/Org 的视觉换行；原书 CJK CSS 仍会丢失。
- **风险**：转换有损，复杂表格、脚注、ruby、SVG 和内部 anchor 易变；Org 编辑可能让位置无法再映射原书；大文件 Org 性能和首次转换时间也需评估。

## 四、横向对比

| 维度 | A. 增强 nov + SHR | B. 新包、语义渲染 | C1. xwidget | C2. EAF | C3. 转 Org |
|---|---|---|---|---|---|
| 可发布 MVP 工程量 | 3～6 人周 | 8～12 人周 | 4～8 人周 | 3～6 人周（不含环境） | 4～8 人周 |
| 后续维护 | 中低；归档上游 + advice/SHR 兼容 | 中高；边界清楚但自担 EPUB 长尾 | 中低；平台/WebKit/桥接 | 低～中；依赖矩阵最大 | 中；转换与映射是长期成本 |
| 纯文本阅读体验上限 | 中 | 中高 | 高 | 高 | 中高 |
| EPUB/CSS fidelity | 低 | 低～中（有意限制） | 高 | 高 | 低 |
| Emacs 原生操作感 | 高 | 最高 | 中低 | 低～中 | 高 |
| CJK reflowable | 中高（需绕过硬填充） | 高 | 高 | 高 | 中高 |
| 稳定进度/注释 | 可做但侵入性高 | 最适合从根上做 | DOM 侧强，桥接复杂 | DOM 侧强，桥接复杂 | Org 侧容易，回映 EPUB 难 |
| 安装与可移植性 | 高 | 高 | 低～中 | 低 | 中（取决于转换器） |
| 最大风险 | 技术债到达临界点 | 范围膨胀、ZIP/EPUB 长尾 | 构建可用性和焦点 | 重依赖和 IPC | 有损转换、双重真相 |

如果唯一成功标准是“在 Emacs 窗口中得到浏览器最接近的 EPUB 视觉效果”，选择 C1；如果成功标准是“Emacs 用户能稳定、舒适地读书并积累本地注释”，选择 B；如果只是尽快改善个人阅读配置，选择 A。

## 五、推荐：B，但把它做成书籍渲染器，不做浏览器

### 为什么不是 A

A 能解决肉眼最明显的 60%：居中窄栏、字号、行距、标题 face、CJK 动态换行、图片 fit-width。但剩余 40% 正好是决定长期质量的部分：TOC 状态、全书位置、重渲染后稳定恢复、注释锚点和 EPUB 长尾。继续做下去需要在 nov/SHR 旁边重新建立 publication 与 locator 模型，此时保留 nov 只剩短期收益，却继续承担归档上游和内部 advice 风险。

### 为什么不是 C

C1 的排版上限最高，但把 Emacs 最强的部分——buffer 文本、keymap、isearch、选择、可访问性和 Org 互操作——换成了 WebView 桥接问题。EAF 又增加沉重运行时。转 Org 适合“导入并做知识管理”，却会制造 EPUB 与 Org 两份内容以及有损映射。它们都偏离“轻依赖、Emacs 原生 EPUB 阅读器”的核心定位。

### B 的关键取舍

路线 B 的卖点不应写成“比浏览器更完整地支持 EPUB”，而应是：

> 对无 DRM、可重排的文字型 EPUB，提供稳定、快速、CJK 友好、完全 Emacs 原生的阅读、导航、进度和本地注释体验。

为守住这个定位，必须公开写下非目标：不实现通用 CSS，不追求出版社像素级版面，不执行 JavaScript，不把固定版式伪装成可支持。

## 六、第一版 MVP

### 6.1 必须做

#### 打开与出版物模型

- 打开无 DRM 的 EPUB 2/3 reflowable。
- 安全读取 ZIP 的 store/deflate 成员；验证路径、大小、压缩比和 CRC；资源解析始终限制在容器内。
- 解析 `mimetype`、`META-INF/container.xml`、OPF metadata/manifest/spine、EPUB2 NCX 和 EPUB3 nav。
- 正确规范化 percent-encoding、fragment 和相对路径；对不规范但常见的书给出可诊断错误，而不是空白 buffer。
- book key 同时使用规范文件身份/内容指纹与 EPUB identifier，避免只靠不可靠 identifier。

#### 正文渲染与排版

- 语义渲染常见文本标签、列表、引用、代码、链接、简单表格 fallback、图片和图注。
- 每个段落保持逻辑文本，不插入随窗口宽度固化的换行；窗口 resize 和 `text-scale-adjust` 后自动视觉重排。
- 提供至少三个用户项：目标阅读栏宽度、行距/段距、variable/fixed pitch；正文栏居中。
- 默认启用 CJK 友好的按字符类别换行与 kinsoku；中英混排时不要求空格才能换行。
- 标题、正文、引用、代码、链接、注释高亮使用独立 face，深浅主题均可读。
- 图片默认按阅读栏 fit-width，提供 fit/original 切换；不支持的图片格式显示 alt 与明确提示。
- 渲染输出保留 source/semantic text properties，能从 point 构造 locator，也能从 locator 回到 buffer。

#### 导航

- 上一/下一 spine item、内部链接、后退/前进历史。
- 独立 TOC buffer：保留层级、可折叠、标出当前章节、重复打开保留位置，`RET` 跳转且不破坏正文窗口布局。
- `completing-read` 跳转任意目录项/标题；header-line 或 mode-line 显示书名、当前章节和全书百分比。

#### 进度、书签和基础注释

- 统一 locator schema；进度、bookmark、highlight/note 共用，schema 带版本号。
- idle debounce、换章和 kill-buffer 时保存进度；使用临时文件 + rename 原子落盘，并合并多个已打开书籍的更新。
- 恢复顺序：element id/DOM path -> text quote + context -> 章节开头，并明确提示是否发生降级。
- 全书百分比按各章节归一化可读文本长度加权。
- 支持单个 spine item 内的连续选区高亮；可附一段纯文本笔记；提供注释列表、跳转和删除。
- 注释只存在 sidecar，不修改 EPUB；保存 quote/prefix/suffix，使轻微结构变化后仍有机会重定位。

#### 质量底线

- ERT 覆盖 container、URL 解析、EPUB2/3 publication、renderer、locator round-trip、store migration/atomic update。
- fixture 至少覆盖：中文小说、中英混排、长章节、多级 TOC、图片书、脚注/内部链接、重复/缺失 identifier、percent-encoded 路径、恶意 `../` 成员和压缩炸弹阈值。
- 大章按章懒加载；打开一本普通文字书到首屏不应先渲染全书。注释和全书长度索引可 idle 增量构建。

### 6.2 第一版明确不做

- DRM、加密 EPUB。
- fixed-layout、漫画双页、竖排、复杂 ruby、MathML、音视频、脚本和交互式内容。
- 通用 CSS cascade/box model、出版社字体嵌入、浮动布局、精确两端对齐和自动断词。
- 跨章节选区高亮、手写批注、多人协作、多设备同步。
- EPUB CFI / Web Annotation / Calibre 注释互操作；MVP 先把内部 schema 版本化，后续再做转换器。
- 修改 EPUB、把注释写回书中、导出完整 Org 副本。
- 全书全文索引和复杂搜索结果 UI；MVP 先保证目录/标题跳转与当前章节 isearch。全文搜索是下一版本优先项。
- 为 Emacs 28 及更早版本维护显示兼容层。

### 6.3 MVP 验收标准

第一版不是以“支持多少 HTML 标签”验收，而以五条用户路径验收：

1. 打开一本文字型中文 EPUB，首屏可在合理时间出现，正文居中、字号/栏宽变化无需重新开书，中文标点换行无明显硬伤。
2. 从正文打开多级 TOC，能看到当前位置、折叠/展开、跳转，再次打开仍停在上次 TOC 位置。
3. 阅读一段后强制重渲染或改变窗口宽度，关闭再打开仍恢复到同一语义段落，而非同一个旧 point。
4. 选择一句话做高亮并写笔记，换章、重开、调字号后高亮仍能恢复；无法精确恢复时给出降级状态。
5. 恶意或损坏 EPUB 不能写出缓存目录、无限解压、执行脚本或静默联网，并给出包含具体成员/阶段的错误。

## 七、建议的实施顺序与决策门

1. **第 0 阶段：2～3 天可行性 spike**。只验证纯 EL ZIP store/deflate、一个 EPUB3 的 OPF/nav、CJK 逻辑段落动态换行和 source-property round-trip。任何一项不成立都先调整约束，不进入 UI 开发。
2. **第 1 阶段：publication + renderer**。先让 fixture corpus 稳定打开，再做漂亮 face；避免用 UI 掩盖模型错误。
3. **第 2 阶段：locator + store**。在 bookmark 和 annotation 之前冻结 v1 locator/schema；用 rerender 测试驱动 round-trip。
4. **第 3 阶段：TOC + progress + 图片**。建立完整阅读闭环。
5. **第 4 阶段：基础 highlight/note**。只支持章内连续选区，用已有 locator；不要让注释系统发明第二套位置协议。

路线 A 可以并行作为一次性体验原型，但代码不直接迁入 B；只把验证过的默认栏宽、行距、face 和按键反馈迁入。这样 A 是需求实验，不是新包的兼容层包袱。

## 参考依据

- [nov.el 上游源码](https://github.com/wasamasa/nov.el/blob/master/nov.el)：0.3.0 的解包、SHR 渲染、TOC、图片覆盖、历史和 `nov-places` 实现。
- [nov.el 上游仓库](https://github.com/wasamasa/nov.el)：仓库归档状态及最后维护时间。
- [GNU Emacs `shr.el`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/net/shr.el)：`shr-width`、填充、有限 style 处理、标签渲染与现代图片能力。
- nov.el 的历史 issue 也直接反映了这些体验缺口：[TOC 位置 #19](https://github.com/wasamasa/nov.el/issues/19)、[全书进度 #30](https://github.com/wasamasa/nov.el/issues/30)、[行宽/两端对齐 #31](https://github.com/wasamasa/nov.el/issues/31)、[中文 #52](https://github.com/wasamasa/nov.el/issues/52)、[字号与宽度 #54](https://github.com/wasamasa/nov.el/issues/54)。issue 只能作为需求证据；能力归因以上游源码为准。
