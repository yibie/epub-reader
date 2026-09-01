# Changelog

本文件记录 epub-reader 的公开版本变化。版本号遵循 Semantic Versioning。

## Unreleased

### Changed

- 容器改为中央目录 preflight 后按需 materialize；启动只展开格式元数据、恢复章节和当前
  viewport 图片，spine 权重直接读取 ZIP 中央目录的未压缩 size。
- 图片解压移到 active chunk 的 TextUI leaf 生产阶段，并缓存已 materialize 成员。
- 图片物理行的 newline 使用 `line-height=t` 忽略继承行距，正文继续保留用户设置；禁止二次
  软折行并隐藏 continuation/truncation fringe，避免居中栏外的单字列。
- 配套 TextUI native image 路径支持带 text properties 的 CJK alt，reader 图片 source anchor 与
  locator 可跨图形切片保留。
- text scale 变化触发完整 TextUI 重排，图片行预算按 remap 后字体高度重算，并以 locator/window
  view state 恢复位置。
- 惰性容器绑定 preflight 时创建的只读归档快照；materialize 前检测外部归档替换，并以容器级
  原子 reservation/commit 维护累计解压预算。

### Performance

- 31.96 MB、164 成员的杂志样书 open→首屏中位数由 1.154 s 降至 0.351 s，首屏落盘成员由
  164 个降至 6 个。

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
