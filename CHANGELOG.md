# Changelog

本文件记录 epub-reader 的公开版本变化。版本号遵循 Semantic Versioning。

## Unreleased

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

### Changed

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

### Performance

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
