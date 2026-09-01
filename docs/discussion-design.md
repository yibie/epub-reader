# 交叉讨论：先产品化路线 A，路线 B 改为长期方向

> 本文修订 `design-options.md` 的路线推荐；事实依据以同目录 `research-ecosystem.md` 为准。

## 1. 前提纠正

旧报告把 GitHub 的 `wasamasa/nov.el` 归档等同于项目停更，这是错误的。上游已迁至 `depp.brause.cc`，NonGNU ELPA 提供 `nov 0.5.0`，2025 年仍有字体 remap、相对路径等修复。当前准确判断是：**维护不算密集，但项目仍维护，且已有 EPUB2/3 TOC、bookmark、Org link、Imenu 和跨 spine multi-isearch。**

这推翻了“继续基于 nov 就必须独自维护整个 EPUB 基座”的关键前提，但不改变另一结论：`shr` 仍不是 CSS/浏览器排版引擎。

## 2. 修订后的推荐

首个实际交付物应选择 **A+：产品化的 nov 增强包**；路线 B 降级为有条件触发的长期方向。

理由：

1. 我们现在的交付目标是“尽快得到可安装、可长期日用的包”，不是先证明能重写 EPUB 栈。
2. nov 0.5.0 已承担容器、OPF/spine、链接、TOC、搜索和兼容长尾；复用它能把时间集中在真正差异化的阅读体验。
3. `shrface`、CJK visual wrapping、`visual-fill-column`、`org-remark-nov-mode` 已证明可以组合；产品机会是把零散配置变成一致、可诊断、可测试的默认体验。
4. A+ 可在约 4～6 人周交付 MVP；B 仍需约 8～12 人周才能追平基础能力，真实 EPUB 长尾还会继续扩大差距。
5. A+ 会产生真实用户数据：哪些书仍不可读、locator 漂移频率、哪些 nov seam 不够用。这些证据比现在猜测 B 的接口更有价值。

结论不是“永远留在 SHR”。A+ 面向文字型、reflowable EPUB；复杂 CSS、固定版式、竖排和漫画明确交给外部阅读器，而不是承诺在 A 或 B 中解决。

## 3. 产品定位与依赖

一句话定位：**安装后即可获得 CJK 友好、居中、可导航、能续读和批注的 Emacs 原生 EPUB 阅读体验。**

- 最低 Emacs 29.1；目标基线 `nov >= 0.5.0`。
- 轻依赖：`nov`、`shrface`、`visual-fill-column`、`org-remark`；不依赖 Python、Node、Qt 或浏览器。
- 入口是一个全局配置命令和一个 buffer-local minor mode；不要求用户复制配置片段。
- 第一次启用运行 capability check，明确报告 libxml、解包程序、图片格式和可选集成状态。

## 4. 模块结构

```text
epub-reader.el                 公共入口、Customize、minor mode、用户命令
epub-reader-nov.el             nov seam：版本/变量/钩子/私有兼容集中于此
epub-reader-presentation.el    CJK profile、居中阅读栏、shrface、图片策略
epub-reader-navigation.el      统一 TOC/标题索引、completion、当前位置
epub-reader-progress.el        locator、idle save、恢复、版本化 sidecar
epub-reader-remark.el          org-remark adapter 与重渲染后的刷新协调
test/epub-reader-*-test.el     各模块接口测试
test/fixtures/                 中英混排、长 TOC、图片、异常 identifier EPUB
README.md / CHANGELOG.md       安装、支持矩阵、迁移与发布记录
```

`epub-reader.el` 是对用户的深模块：公开 `epub-reader-setup`、`epub-reader-mode`、`epub-reader-toc`、`epub-reader-jump`、`epub-reader-annotate` 五个主要入口，其余复杂性隐藏在实现中。

`epub-reader-nov.el` 是唯一允许知道 nov 内部符号的模块。优先使用公开 hook/变量；必须 advice 时只做 buffer-local 行为、集中登记并测试版本。其他模块不得直接 advice nov/SHR，以保留维护 locality。

现在不虚构“可替换 renderer 接口”：只有 nov 一个实现时，这会是浅模块。等 B 原型成为第二个 adapter，再从两者真实共同点提取 seam。

## 5. v0.1 功能清单

### 开箱即用

- `.epub` 仍由 `nov-mode` 打开，`epub-reader-mode` 自动启用；提供一键关闭以回到裸 nov。
- 预设 `book`、`compact`、`code-heavy` 三个 profile；深浅主题只引用 face，不硬编码背景色。
- 中文默认：禁用 SHR 硬填充，开启 `visual-line-mode`、`word-wrap-by-category`、`kinsoku`；中英混排无需空格才能换行。
- 居中阅读栏：默认 72 列、可 Customize；窗口 resize 和 text scale 后动态调整，不改正文 point。
- `shrface` 提供标题层级、列表、引用、代码和链接样式；允许用户局部覆盖 face。

### 导航与图片

- `epub-reader-toc` 打开层级 TOC，保留上次目录位置并标出当前章节。
- `epub-reader-jump` 用 completion 统一目录项和 Imenu 标题；保留 nov 的 history、跨章搜索和链接行为。
- header-line 显示书名、章节和近似全书进度，并明确标记“估算”而非伪装页码。
- 图片默认 fit-width，保留宽高比；提供 fit/original 切换，resize 后 debounce 重算；失败时显示 alt 和格式诊断。

### 可靠进度

- 不替换 nov 的原生 `nov-places`，另存版本化 sidecar，便于回退和迁移。
- locator 保存书籍指纹、spine href/index、point、当前段落 text quote 及前后文；公开数据不只暴露 nov index/point。
- idle、换章、kill-buffer 三个时机 debounce 保存，临时文件 + rename 原子落盘，多 buffer 更新先合并。
- 恢复依次尝试 href + quote/context、附近 quote、旧 point、章节开头；降级时提示一次并留下诊断记录。
- “可靠”限定为同一文字版 EPUB 在字号、栏宽和轻微 SHR 变化后恢复同一段；不宣称 EPUB CFI、跨版本书籍同步或跨设备一致。

### org-remark 集成

- 自动加载 `org-remark-nov-mode`，提供统一 annotate 命令、默认高亮 face、sidecar 位置和注释列表入口。
- 换章/重渲染后协调 org-remark 重新应用高亮；失败时不吞掉 orphan annotation，并提供重新定位入口。
- 不复制 org-remark 的存储和编辑功能；本模块只是 adapter，防止产生第二套注释数据库。

## 6. v0.1 明确不做

- 通用 CSS、出版社版式复原、固定版式、竖排、DRM、音视频和脚本。
- 自写 EPUB ZIP/OPF/XHTML parser、自写高亮数据库、自写全文搜索。
- 稳定 EPUB CFI、跨设备同步、跨不同版本 EPUB 的无损注释迁移。
- 全局 advice `shr`，或让增强影响 EWW/Gnus 等其他 SHR buffer。

## 7. A 到 B 的演进关系

A+ 不是一次性配置包，而是需求与接口的验证层；可复用的是产品接口、默认 profile、TOC 索引记录、locator schema、fixture corpus 和验收测试。应丢弃的是 nov/SHR advice、图片 handler 及 `org-remark-nov-mode` adapter。

为 B 预留但不提前抽象：导航索引使用 `(label depth target)`；持久化 locator 保存 `spine-href + quote/context`；公共命令和存储格式不带 `nov-` 名称。这样 B 可读取 A 的进度/注释线索，而无需模仿 nov 的 buffer 实现。

只有满足以下任一条件才正式启动 B：目标文字书中超过 10% 因 SHR 无法达到验收标准；进度/高亮在同一 EPUB 重排后的恢复率达不到 99%；需要三处以上 nov 私有 advice；或上游拒绝我们必须依赖的稳定 seam。若痛点是浏览器 fidelity，则应转外部/xwidget 路线，而不是误把 B 当成 CSS 引擎。

因此路线图是：**先发布 A+ 并测量，再决定是否用 B 替换 publication/renderer；B 是可证伪的战略选项，不是预先承诺的重写。**
