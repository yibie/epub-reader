# Changelog

本文件记录 epub-reader 的公开版本变化。版本号遵循 Semantic Versioning。

## 0.3.1 - 2026-09-05

### Fixed

- 修复普通宽度下含图片的章节也可能报
  `Refresh region chapter must occupy complete lines`：图片像素宽度取整会让同级布局多出一格，
  TextUI 现在会让外层布局补出的空格继承完整行 refresh region 的所有权。0.3.0 对极窄窗口的
  降级仍然保留，但不再承担这个通用布局问题。

## 0.3.0 - 2026-09-04

### Changed

- 用 `package-vc-install` 安装时不再字节编译 `test/` 目录下的测试和 fixture 文件：
  `test/.dir-locals.el` 标记了 `no-byte-compile`，安装日志不再出现测试文件的报错。
- 每个阅读会话的目录、书签和标注列表共用一个受控 panel host：重复按对应命令会聚焦已有视图，
  切换类型会复用同一容器；终端 fallback 在窄窗口下压缩或移到底部，避免过度挤占正文。
- 高亮笔记改用多行编辑窗口：`RET` 换行，`C-c C-c` 保存，`C-c C-k` 放弃；编辑完成后
  自动收回窗口并恢复焦点，同一条标注只保留一个编辑器，关闭含未保存笔记的阅读器前会询问。
- 目录新增 `n` / `]`、`p` / `[` 章节导航和 `t` / `q` 关闭键；激活目录、书签或标注条目时
  会重新显示并聚焦正文。
- 高亮列表新增 `n` / `p` 条目导航；列表内按 `a` 或 `q` 均会关闭侧栏并返回正文。
- 图形 Emacs 中的目录、书签和高亮列表默认共用覆盖正文右上方的 child frame，不再改变正文
  可用宽度；终端或 child frame 创建失败时自动回退到单个受控侧栏/底栏，并可用
  `epub-reader-panel-display` 强制选择。
- child frame 改用像素级尺寸、实测外框宽度和父 frame 边界定位，并清除 fringe/scrollbar、
  增加可配置的内缩留白与细边框；父 frame 或正文窗口改变尺寸后会自动重新约束位置。
- 用户关闭列表时隐藏并保留可复用 host，阅读会话结束或所属 buffer/frame 死亡时才最终销毁；
  child frame 默认隐藏 mode line，可用 `epub-reader-panel-show-mode-line` 重新显示。
- child frame 强制关闭 frame tab bar 和窗口级 tab line，不受全局 `tab-bar-mode` 或 buffer
  的 `tab-line-mode` 设置影响。
- 目录、高亮和书签合并为一个面板 buffer：第一行是 Contents、Highlights、Bookmarks 三个
  widget 标签按钮，鼠标点击或按 `RET` 切换视图，任一视图中 `1` / `2` / `3` 和 `t` / `a` / `M`
  也可切换。此前标签放在 header-line 上，在 macOS 上点击会被改写成 `<header-line> <mouse-2>`
  而报 undefined；改为正文内的 widget 后走 `widget-button-click`，不再依赖 header-line 事件。

### Fixed

- 极窄或正在调整大小的窗口不再因 chapter refresh region 被外层 chrome 补宽而报
  `Refresh region chapter must occupy complete lines`；宽度不足时优先保留可刷新的正文，
  恢复宽度后再显示 header/footer。
- child frame 面板改按阅读窗口 body 的像素边界定位，不再压住正文的 header line 和 mode line。
- 长章节连续翻页不再在章节中后段退化为逐段滚动；跨章节后继续维持有界、重叠的页面 chunk。
- XHTML 外层元素的空白判断不再受调用 buffer 的 syntax table 影响，避免重开 EPUB 后正文段落
  偶发塌成一个大文本块并触发不必要的降级恢复。
- 首屏恢复同时遵守 block 与 character 预算，并从解析出的目标位置开始；精确位置失效时仍保留
  quote-in-spine 等语义降级恢复。
- 非全屏模式按 `q` 不再删除用户原有分栏；笔记编辑器也不再占用或拆除其他阅读会话的窗口。
- 已与布局解绑的目录或列表仍可关闭，并能在导航时安全恢复所属 reader，而不会覆盖另一本书。

## 0.2.0 - 2026-09-01

### Added

- 书签支持：当前位置命名、段落预览、独立 TextUI 列表、跳转与删除。
- 标注支持：同一 spine 内连续文字高亮、纯文本笔记、按章节分组的 TextUI 列表，以及
  `RET` 跳转、`d` 删除和 `e` 编辑笔记。
- 高亮使用来源范围和引文上下文双重锚定；窗口宽度、字号、重排或重开后恢复，按引文降级定位时
  使用警告样式并给出提示。
- sidecar 升级到 schema 2，平滑读取 0.1.0 的 schema 1 进度；书签与标注按独立条目合并，支持
  同一本书多 buffer 并发新增而不互相覆盖。
- 新增纯英文和中英混排 EPUB fixture，覆盖 Latin 词间断行、非末行对齐、混排来源位置与高亮
  引文重定位。
- 目录、书签列表和高亮列表支持鼠标点击条目跳转，效果与 `RET` 相同。
- 新增阅读字体与排版设置：标题和引用继承 `epub-reader-prose-face`，并提供
  `epub-reader-text-scale`、`epub-reader-line-spacing` 和
  `epub-reader-paragraph-spacing`。

### Changed

- 安装说明改为优先用 `package-vc-install` 从 GitHub 安装 TextUI 和本包，克隆后加入
  `load-path` 的方式保留为备选。
- 引用块和代码块不再绘制边框：按字符格计算的边框在比例字体正文里对不齐。引用仍用斜体灰字，
  代码仍用等宽灰底区分。
- 打开书后阅读 buffer 独占当前 frame，`q` 退出时恢复原来的窗口布局；新增
  `epub-reader-open-full-frame` 开关（默认开启）。
- 容器改为中央目录 preflight 后按需 materialize；启动只展开格式元数据、恢复章节和当前
  viewport 图片，spine 权重直接读取 ZIP 中央目录的未压缩 size。
- 图片解压移到 active chunk 的 TextUI leaf 生产阶段，并缓存已 materialize 成员。
- reader 保存用户行距、以零行距作为图片基线，再把原值逐行加回正文 newline；图片行使用
  `line-height=t`，图形像素回归为图片 14px、正文 17px。继续禁止二次软折行并隐藏
  continuation/truncation fringe，避免居中栏外的单字列。
- 配套 TextUI native image 路径支持带 text properties 的 CJK alt；combining/variation 字符不会
  击穿固定列 splice，letterbox 的 anchor 固定在 leaf 第 0 行，caption 不再被误标为图片行。
- text scale 变化触发完整 TextUI 重排，图片行预算按 remap 后字体高度重算，并以 locator/window
  view state 恢复位置。
- 惰性容器绑定 preflight 时创建的只读归档快照；materialize 前检测外部归档替换，并以容器级
  原子 reservation/commit 维护累计解压预算。
- publication 将暂态 materialize busy 转译为资源层错误，renderer 不再依赖 container 异常。

### Fixed

- 在阅读 buffer 里再打开另一本书时不再报 "EPUB reader session is unavailable"：
  新 buffer 在首次渲染前就持有自己的 session。
- 目录条目过长换行后，续行跟随标签起始列缩进，不再顶格显示：目录行改为"标记格 + 标签格"的
  TextUI 行布局，续行空白处按 `RET` 或点击仍能定位到该条目。
- 高亮列表的章节分组标签不再写死为英文 "Chapter N"：优先用章内第一个标题，其次用目录标题，
  都没有时按书的语言编号（中文、日文显示"第二章"，韩文显示"제2장"，其他语言仍为
  "Chapter 2"）。阅读 buffer 的 header 采用同样的回退顺序。

### Performance

- 标注解析新增独立的惰性索引：打开高亮列表不再遍历和重新定位全书标注，跳转时才校验对应
  引文；章节渲染、列表重开和重复跳转共享按来源代际失效的解析缓存。
- EPUB 向 TextUI 提供稳定的段落 cache key；缓存同时绑定实际像素宽度、字体、主题和排版策略，
  因此侧栏宽度来回切换时可复用已有排版，而不是再次规划整个可见 chunk。
- 长章节 chunk 改用 TextUI 0.7 的 keyed region reconcile：滑窗保留重叠 block，只排版新进入或内容变化的 block；达到完整 chunk 后不再为每次滚动追加一次冗余 idle recenter。冷滚动新增量限制为半个 guard，避免一次同步排版一整屏新段落。
- 31.96 MB、164 成员的杂志样书 open→首屏当前中位数为 0.284497 s，其中 archive snapshot
  I/O 中位数为 0.016526 s；整包解压历史基线为 1.154237 s，首屏落盘成员由 164 个降至 6 个。
- 章节首绘缩到约一屏，完整 viewport 与下一章 DOM/blocks 移到 idle；图片先显示固定尺寸占位，
  只在 idle 路径 materialize，再以 TextUI region refresh 替换。滚入新 chunk 会继续排队图片。
- EPUB 正文默认使用 TextUI 的 kinsoku-aware greedy 布局，并复用有界 attributed paragraph
  cache；greedy 与可选 balanced Knuth--Plass 都保持非末行两端对齐。cache=0 直接规划，解析后
  face 及 theme/font generation 参与失效。locator source 扫描也按 buffer generation 缓存。
- 所有 source-order chunk refresh 都以 reader locator/viewport 为真值恢复；guard 不再执行只
  丢弃上下文却不增加覆盖的 shift，避免滚动改变 locator、视觉行与持久进度。
- 财新杂志普通章节 batch 换章由 1.067 s 降到 0.125 s；图形帧在下一章预取命中时由
  3.362 s 降到 0.050 s。连续图形滚动 p95 为 0.039 s，详见 `docs/perf-notes.md`。

## 0.1.0 - 2026-08-31

首个可用开发版本。

### Added

- 基于 TextUI 的原生 Emacs EPUB 阅读界面，支持居中正文栏、宽度变化重排与 CJK common
  kinsoku 折行。
- EPUB 2/3 OCF、OPF、manifest、spine、NCX/nav 解析，以及统一的 href/fragment resolver。
- 段落、标题、强调、引用、代码、列表、简单表格降级、图片与内部/外部链接渲染。
- block/character 双预算 viewport、guard/overscan、region refresh，以及 chunk shift 后的
  locator、point、window row 恢复。
- 前后章与章尾自动导航、locator history、层级折叠 TOC、标题补全跳转和全书加权进度。
- 基于规范路径、文件属性与内容 hash 的书籍身份；版本化 locator 与 exact/degraded fallback。
- 位置变化 idle debounce、换章/关闭保存；versioned sidecar、条目级单调合并与原子事务锁。
- `unzip`/`bsdtar` 流式 adapter，包含 OCF 路径验证、Unicode full case-fold 去重、成员清单与
  解压资源上限、恶意路径防护。
- EPUB2/3、CJK、图片、10k 段长章及并发/恶意输入 fixtures；0.1.0 发布基线共 79 个 ERT。

### Known limitations

- 不支持 DRM、fixed-layout、竖排、完整 CSS、复杂 ruby/MathML/SVG、音视频、JavaScript、
  标注/笔记、全文索引搜索与跨设备同步。
- 单个超长语义块可超过 viewport 字符软预算；章节间进度权重仍按 XHTML byte size 估算。
- sidecar 锁依赖本地文件系统的同目录原子 rename 语义；特殊/网络文件系统、多进程长期压力和
  crash 残留垃圾回收尚未覆盖。
