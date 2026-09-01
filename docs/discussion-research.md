# 生态交叉讨论：不应先重写 EPUB 阅读器

> 截至 2026-08-31；检索范围：GitHub 仓库/源码搜索、MELPA/MELPA Stable、GNU/NonGNU ELPA、Doom/Spacemacs 官方仓库及相关项目源码。

## 结论

不支持 `design-options.md` 推荐的路线 B 作为当前产品路线。它把一个可发布产品估成 8–12 人周，实际却同时承诺 ZIP/OCF、EPUB2/3 publication、HTML 语义渲染、URL/资源解析、locator、store、搜索、TOC、图片、注释和恶意输入防护；其中前半已经由维护中的 `nov`/`shr` 提供，后半才是用户真正缺的阅读器 UX。更现实的路线是发布一个 **正式的 `nov` 增强包**，先验证生态需求和 locator 可行性，再决定是否抽换底层。

## 1. 对路线 B 的生态批判

1. **重复造轮子。** 当前 [`nov` 0.5.0](https://elpa.nongnu.org/nongnu/nov.html) 已有 EPUB2 NCX、EPUB3 nav、manifest/spine、相对链接、图片、历史、Bookmark、Org link、Imenu 和跨 spine multi-isearch；`shr` 又是 Emacs 核心持续维护的 HTML→buffer 渲染器。路线 B 的 container/publication/renderer/UI 六模块会先重写大量“已有但不精致”的代码，而不是优先补阅读栏、TOC、进度和集成。
2. **“语义白名单”仍有巨大长尾。** EPUB 3 的内容模型继承 HTML，并允许 CSS、SVG、MathML、媒体、脚本、远程资源与 fallback；OCF 还有大小写敏感路径、URL/percent encoding、字体混淆等规则（[W3C EPUB 3.3](https://www.w3.org/TR/epub-33/)）。即使明确拒绝 fixed-layout/JS，空白折叠、列表/表格、脚注、ruby、实体、图片 MIME、坏 XHTML 和 legacy EPUB2 仍会持续扩张白名单。
3. **纯 Elisp ZIP 的前提有误。** Emacs 的 [`zlib-decompress-region`](https://www.gnu.org/software/emacs/manual/html_node/elisp/Decompression.html)只接受 gzip 或 zlib 包装的数据，不能直接充当 ZIP method 8（raw DEFLATE）读取器；内置 Archive mode 也只原生读目录，提取 ZIP 仍调用外部程序（[Emacs 手册](https://www.gnu.org/software/emacs/manual/html_node/emacs/File-Archives.html)）。因此 central directory、ZIP64、CRC、data descriptor、raw-deflate 适配和 zip-bomb 防护不是 2–3 天的常规“接线”。
4. **locator 是必要方向，不是重写渲染器的充分理由。** [`nov` 当前源码](https://github.com/emacs-pe/nov.el/blob/master/nov.el)已保留 `shr-target-id`、spine 文件、渲染前后 hook 和可替换 renderer；增强包可先保存 `book fingerprint + spine href + element id + text quote/before/after`。这与 [Readium Locator](https://readium.org/architecture/models/locators/) 和 [W3C TextQuoteSelector](https://www.w3.org/TR/annotation-model/#text-quote-selector) 的思路一致；DOM path/字符偏移仍会受内容修订、空白归一化和重复文本影响，新 renderer 不会自动让它可靠。
5. **8–12 人周只够 happy-path 原型。** 报告自己又承认“真实兼容”需 4–6 人月，却把安全容器、坏书容错、稳定高亮恢复和可发布质量同时列入 MVP；两者矛盾。若目标是替代已存在十年的 reader，fixture、平台、Emacs 版本和用户书库长尾还会带来长期维护税。

## 2. 是否已有开箱即用的 `nov` 套件

| 候选 | 检索结果 | 判断 |
|---|---|---|
| `nov-setup` / `nov-config` | 精确名称与描述的 GitHub 仓库搜索均无成品；[MELPA 索引](https://melpa.org/archive.json)、[NonGNU ELPA 索引](https://elpa.nongnu.org/nongnu/archive-contents)也无同类套件 | **未发现可安装产品** |
| Spacemacs `epub` layer | [官方 layer](https://github.com/syl20bnr/spacemacs/blob/develop/layers/%2Breaders/epub/packages.el)只安装 `nov`、声明文件关联并加 Evil 键位；“居中”仍提示用户手动 `SPC w c` | 分发层包装，不是增强套件 |
| Doom Emacs | 官方主仓库检索无 EPUB/`nov` module；可找到的 [`nov.el-module-doom-emacs`](https://github.com/honuonhval/nov.el-module-doom-emacs)是 0-star、2-commit 私有模块，只装 `nov` 并改 `nov-save-place-file` | 非官方、非增强套件 |
| `shrface` | [可安装且活跃](https://github.com/chenyanming/shrface)，提供 Org 风格 face、outline、Imenu/标题导航；README 的完整搭配明确称“个人配置，供参考” | 真包，但只覆盖 SHR 外观/导航 |
| `org-remark` | [GNU ELPA 成品](https://github.com/nobiot/org-remark)，有专门 `org-remark-nov-mode`、Org sidecar 高亮/批注 | 真包，但只覆盖标注 |
| 其他 nov 扩展 | `eldoc-mouse-nov` 只预览脚注链接；`nov-xwidget`/`nov-web` 改渲染出口；大量 `use-package`/dotfiles 组合 `visual-fill-column`、字体和键位 | 单点扩展或可复制配方 |

因此，生态里有“零件”和许多可复制配置，却没有一个由维护者承担默认值、版本兼容、迁移、测试和文档责任的 **一键 reader profile**。这正是配置片段与可安装产品的分界。

## 3. 这个空缺是否值得发布

**值得，但产品边界必须是 `nov` 的体验/状态层，而不是另一套 EPUB/HTML 引擎。** 目标用户明确存在：想保留 Emacs buffer、搜索和 Org，又不愿自己拼 4–6 个包；`nov` 仍活跃、依赖轻，恰好适合作为稳定底座。

建议包（暂称 `nov-reader`）提供一个可撤销的 minor mode：

- CJK profile：`nov-text-width=t`、`visual-line-mode`、`word-wrap-by-category`/`kinsoku`，并避免污染非 `nov` buffer；
- window-local 居中阅读栏、字体/行距/主题和 resize 处理；`visual-fill-column` 可选，不作硬依赖；
- 独立 outline TOC + `completing-read` 快跳、当前章节标记、重复打开保留 TOC point；
- 阅读栏/header-line：章名、章内与全书进度；按各 spine 归一化文本长度缓存权重，不伪装成纸页数；
- versioned sidecar locator：指纹、href、id、quote/context、回退等级，idle/换章/kill 时原子保存；先做“可靠继续读”，不宣称 CFI/跨阅读器同步；
- `org-remark` 仅作可选 feature 与默认 glue，复用其高亮/Org 数据库，不重写注释系统；`shrface` 同样软集成。

真正难点是 locator 与跨版本恢复，应做成独立模块和 fixture corpus；排版/TOC/profile 不应因此被阻塞。只有当 50–100 本真实 EPUB 证明 `nov` hook/现有 DOM 与文本属性无法提供所需锚点，才升级为替换 publication/renderer 的决策门。

## 4. `design-options.md` 的事实错误与过时判断

| 报告结论 | 纠正 |
|---|---|
| “上游归档、0.3.0、停在 2020” | 归档的是旧 GitHub；项目已迁至 [depp 上游](https://depp.brause.cc/nov.el/)，NonGNU ELPA 稳定版为 0.5.0，现代 [GitHub 镜像](https://github.com/emacs-pe/nov.el)在 2025-12 仍有修复。路线 A 的维护风险被严重高估。 |
| 图片实现“来自 2020、依赖旧 ImageMagick 分支” | 0.5.0 已用 `create-image :max-width/:max-height`、兼容 `image-transforms-p`，并有近年 SVG workaround；仍落后现代 SHR zoom、忽略标签尺寸，但不是原报告所据的 0.3.0 原样。 |
| 普通搜索天然只搜当前章、`nov` 无全书搜索 | 没有**索引式搜索结果 UI**属实；但 0.5.0 已设置 `multi-isearch-next-buffer-function`，README 明列 Info-style incremental search，不能写成跨章搜索完全不存在。 |
| Bookmark/Org/TOC/图片能力被当成待重写项 | 0.5.0 已有原生 Bookmark handler、带 metadata 的 Org stored link、EPUB2/3 TOC、Imenu、图片 fallback；TOC 替换正文且不记目录 point 的 UX 问题仍真实，适合在增强层修。 |
| C2 EAF 需从零集成 3–6 周 | 2026-08 已出现 [`eaf-ebook-viewer`](https://github.com/chenyanming/eaf-ebook-viewer)：直接嵌 Calibre 8.7 viewer，已有 TOC/search/bookmark/highlight/note/TTS 和 Emacs hooks；它很新且构建很重，但改变了“从零写 EAF 后端”的比较基线。 |
| C1/其他替代主要按自研估算 | 已有 [`nov-xwidget`](https://github.com/chenyanming/nov-xwidget)、[`nov-web`](https://github.com/chenyanming/nov-web)、内置 DocView+MuPDF 和活跃 [`emacs-reader`](https://codeberg.org/MonadicSheep/emacs-reader)。它们各有平台/文本操作代价，但应作为 buy/extend 基线，而非只比较三条 greenfield 路线。 |

## 决策与第一交付物

先否决路线 B 的 8–12 周承诺，选择“路线 A′：成品化、少 advice、软集成”的可逆路径。**第一交付物应是一个可安装的 `nov-reader-mode` 纵向切片：CJK/居中阅读栏 + 独立/快速 TOC + header-line 加权进度 + versioned locator sidecar 恢复 + 可选 `org-remark` 开关，并带 EPUB2/3/CJK/重复文本 fixture 与 ERT。** 它直接填生态空缺，也会产生是否真的需要新 renderer 的证据。
