# 标注阶段审计

审计日期：2026-09-01

初审范围固定为 `git diff a6c7732...5ac7676`。修复复核范围固定为
`git diff 5ac7676...8db20a4`。功能提交为：

- `fd2aa85`：range locator 与英文/混排布局契约；
- `a5fc3b5`：sidecar schema 2、书签/标注持久化与迁移；
- `94706d6`：书签、标注和列表 UI；
- `aaf4126`：图片 slice 不再被当作可高亮文字；
- 其余提交为 README、英文 UI 文本与 CHANGELOG 同步。

本轮以用户给出的五项验收要求为 spec，并参考 `docs/design-options.md:289-312` 与
`docs/architecture.md` 的 locator/store/UI 模块边界。私有样书
`The Economist-04.07.2026.epub` 只读打开；所有 sidecar 探针均写入随机临时目录，没有在样书旁
创建或修改文件。

当前 HEAD 完整执行 `./test/run-tests.sh`：**123 项，121 passed，0 unexpected，2 个 GUI-only
用例按预期 skipped**。新增回归在修复前提交上确会失败，说明不是只会证明现实现状的空测试。

## 结论先行

**Gate 暂不解除。** R-01、R-02、S-01、U-01、U-02 已关闭；R-03 的 schema 999 反例也已关闭，
但同一 finding 要求的端点顺序防御只覆盖同 block。独立探针把持久 range 构造成
`b2:0 -> b1:5`，decoder 接受，resolver 又把反向范围降级为 `quote` 并锚到 `b2:0..6`，没有返回
`invalid-range`。这是确定性的坏 sidecar 错锚，不是微秒级理论竞态，故 R-03 只能判部分解决。

| 级别 | 数量 | Finding |
|---|---:|---|
| P0 阻断 | 0 | — |
| P1 应修 | 1 | R-03（部分解决） |
| P2 建议 | 3 | T-01、A-01、D-01 |

Gate 解除只剩一项：range resolver 在两个 endpoint 均能映射到 canonical chapter index 时，必须先
拒绝 `start-index > end-index`，再允许 exact/quote fallback，并增加跨 block 反向回归。A-01、
T-01、D-01 不单独阻断。

## 修复复核摘要

### Standards

- 生产代码仍无 `textui--*` 私有调用；canonical chapter index 归 locator 所有，UI 通过 locator
  API capture/resolve，没有新增模块越界。
- marks-only 读取、live list 刷新与跨章节 annotation 解析均沿用 store/locator 的既有公开 seam。
- R-03 的 decoder 只能就 schema/identity 和同 block offset 做结构校验；跨 block 顺序必须由已有
  canonical mapping 的 resolver 校验。当前 `epub-reader-locator.el:659-688` 在发现
  `start-index > end-index` 后直接进入 quote fallback，违反 range 的有向顺序不变量。

### Spec

- 独立 Economist 探针跨过真实视觉折行吞掉的空格，capture 得到
  `" tearing it down. Edwar"`，与 canonical substring 一致；改变 text scale/宽度后仍为 `exact`。
- 重复 quote 探针回到原 block `b2:4..10`，完全同分返回 `ambiguous`；marks-only sidecar 重开后
  locator=nil、warning=nil，1 个 bookmark 与 1 个 annotation 均可读。
- live bookmark/annotation list 与未访问章节 degraded 警告回归通过；但反向跨 block range 被错当
  `quote`，因此本轮 spec 尚未全部满足。

## 双轴初审摘要

### Standards

- 生产代码没有调用 `textui--*`；测试为固定宽度读取了 TextUI 私有测试 seam，但未形成生产依赖。
- `epub-reader-store-load-locator` 把合法的 marks-only book record 当成坏 locator，随后用 store-wide
  warning 阻断书签/标注读取，破坏 store 内进度与 reader marks 的独立共存。
- range plist 只验证外层 schema，不验证两个 locator endpoint 的 schema 3；range resolver 也未
  防御，版本化边界形同虚设。
- quote resolver 的同分策略固定取全章第一个命中，没有落实架构中的 near-block 优先级。
- 判断性建议：UI 用五元 positional list 组 canonical record，并为每条标注重复扁平化全章，形成
  Primitive Obsession/Data Clump 与不必要的 `annotations × chapter characters` 成本。

规范轴共 4 个问题（3 个 P1、1 个 P2），最严重为 marks-only 读取、endpoint schema 与 quote 错锚。

### Spec

- P0：真实英文跨折行选择丢掉源空格，range 无法在 canonical records 中 exact/quote resolve。
- P1：重复 quote 会静默选错；degraded 列表警告在重开、未访问章节与跳转后都不可见。
- P2：新增 fixture 与 114 项测试没有覆盖跨空格的 range、真实 text scale、明暗主题、列表完整闭环
  以及进度/书签/标注同次迁移。
- 正向结果：混排无空格选区可跨 width/text-scale/reopen exact 恢复；schema 1 迁移、原子锁与双
  buffer 独立标注合并通过；新键在各自 mode map 中无重复绑定。

需求轴共 4 个问题（1 个 P0、2 个 P1、1 个 P2），最严重为英文跨行高亮不可持久恢复。

## 独立探针摘要

| 检查项 | 独立结果 | 判定 |
|---|---|---|
| 中英混排选区 | `Emacs阅读EPUB` 经真实 `text-scale-set 1` 后仍有 annotation id/face；关闭重开为 `exact` | 通过，但没有空格，未覆盖 R-01 |
| Economist 英文折行 | 章节 18 的 9,476 字符正文在 54 列形成 183 行；0 次词内拆分，182 个非末行均有 justification property | 所测断词/对齐通过 |
| Economist 跨行 range | 复核 capture 与 canonical 均为 `" tearing it down. Edwar"`；scale/宽度变化后 resolve=`exact` | **已解决，R-01** |
| quote 多处命中 | 复核原锚点回到 `b2:4..10`；无法消歧时返回 `ambiguous` | **已解决，R-02** |
| 合成空白 | 带无 source 的 synthetic space/newline 的 `中 … 文` 捕获为 `中文` | 通过 |
| 图片边界 | 纯 image slice 报 `The selected region contains no EPUB text`；image+caption 只捕获一次 `[测试封面]` | 通过 |
| endpoint schema/顺序 | schema=999 已拒绝；但 `b2:0 -> b1:5` 被 decode 并错解为 `quote` | **部分解决，R-03** |
| frozen v1 迁移 | 旧 fixture 升到 schema 2 后进度 path 保留，bookmark=1、annotation=1，无残留 lock | 通过 |
| marks-only 重开 | locator=nil、warning=nil，bookmark=1、annotation=1 | **已解决，S-01** |
| 双 buffer 合并 | 两个 reader 独立添加高亮、逆序关闭，重开为 2 条；item-level merge/锁测试全绿 | 通过 |
| 列表闭环 | annotation list 的编辑笔记、跳转到 `id:mixed`、删除后 remaining=0 | 通过 |
| 存活列表更新 | 重新显示后 bookmark/annotation list 都显示新增的第 2 项 | **已解决，U-01** |
| degraded 提示 | 未访问章节在列表预解析为 `quote` 并显示 `⚠`，跳转后列表仍保持警告 | **已解决，U-02** |
| 明暗主题 | Leuven/Wombat 下均解析为背景 `#fff2a8`、前景 `#1f1f1f`；degraded 有 wave underline | 通过，约 14.6:1 对比度 |
| 键位 | reader 的 `m/M/h/e/a` 均唯一；TOC 不继承；bookmark list 为 `RET/d/q`，annotation list 为 `RET/d/e/q` | 通过 |

## Findings

### R-01 — P0 阻断：英文跨视觉行选区丢失源空格，高亮第一次刷新即消失

**复核结果：已解决。** `epub-reader-locator-range-capture` 现在只从 buffer 取有序端点，再借
`epub-reader-locator-chapter-index` 重建 canonical exact/prefix/suffix；UI 在创建高亮时传入当前章
index。独立 Economist 探针跨真实隐藏空格，capture 与 canonical 完全一致；`text-scale-set 1`、
宽度 54→42、持久 plist decode 后仍 resolve=`exact`。新增 fixture/UI 回归也覆盖创建后的 refresh。

- **位置：** `epub-reader-locator.el:355-427`；`epub-reader-ui.el:1906-1928`；
  `test/epub-reader-annotation-test.el:87-167`。
- **问题：** `epub-reader-locator--source-characters` 只枚举渲染 buffer 中实际存在、仍带
  `epub-reader-source` 的字符。TextUI 在英文空格处折行时不画出作为断点的源空格，因此
  `range-capture` 的 `selected` 缺少该 canonical offset；`:exact`、`:prefix`、`:suffix` 都从这份
  不完整的显示字符序列拼出。保存后 `epub-reader-add-highlight` 立即 refresh，resolver 却拿 quote
  对照完整 semantic block，既不能 exact，也找不到缺空格的 quote。
- **证据：** 只读 Economist 章节 18、54 列，在 source offset `44 -> 46` 的行边界选取两侧文字。
  canonical substring 是 `"sary of its independenc"`，capture 是
  `"sary of itsindependenc"`，resolution quality 为 `none`。这是正常英文 prose，不需要恶意 EPUB
  或竞态。
- **影响：** 任何包含一次普通词间折行的英文高亮都可能保存即消失；改窗口、改字号和重开只会
  重复失败。当前 `Emacs阅读EPUB` 回归没有空格，所以给出了虚假的安全感。
- **修复建议：** capture 只从 buffer 确定有序 endpoint `(block, offset)`，然后通过 locator 模块的
  canonical chapter index 重建 endpoint 之间的 text/context，不能从已排版 glyph 反推 source。
  UI 可把一次构建的 typed canonical index 传入 range API。回归必须让英文选择跨过一个实际被折行
  消耗的空格，并分别断言创建后 refresh、宽度变化、`text-scale-set`、sidecar 重开均保留 exact
  quote、spans、face 和 annotation id。

### R-02 — P1 应修：重复 quote 在 context 同分时静默跳到全章第一次出现

**复核结果：已解决。** 候选现按部分 prefix/suffix 分数、原 block、offset 距离排序；原反例从
`b1` 错锚改为 `quote -> b2:4..10`，两个候选完全同分时返回 `ambiguous` 且 spans=nil。

- **位置：** `epub-reader-locator.el:471-496,538-548`；对应架构
  `docs/architecture.md:243-246`。
- **问题：** context score 只有“完整 prefix/suffix 命中”或 0；任一字符变化就丢掉整侧信息。
  `--range-quote-index` 只在 `score > best-score` 时换候选，所以并列永远保留第一次命中，也没有使用
  原 block/offset 的距离。结果仍标 `quote`，调用者无法知道发生歧义。
- **证据：** 原 range 在 `b2` 的第二个 `target`；新 records 的 `b1`、`b2` 各有一个 target，且旧
  context 都失配。解析结果为 `(("b1" 3 9))` 而非近原锚点的 `b2`。
- **影响：** 书中常见短句、章节标题、引用重复时，编辑版 EPUB 或 block-key 变化会把高亮悄悄移到
  错误位置，错误结果还会以“已恢复”展示。
- **修复建议：** 候选排序至少加入原 block 是否相同、source offset 距离、部分 prefix/suffix
  相似度；最高分并列且无法消歧时返回 `ambiguous`/`none`，不要猜第一处。补同 block 多次、跨 block
  多次、context 部分变化和完全并列四组回归。

### R-03 — P1 应修：range 接受不受支持的 endpoint locator schema

**复核结果：部分解决。** endpoint schema=999 的 persisted decode 已报错，内存 range resolver
返回 `unsupported-schema`。但 decoder 对不同 block 跳过 offset/顺序检查，resolver 也未在已映射的
`start-index=6 > end-index=5` 时返回 `invalid-range`；独立 `b2:0 -> b1:5` 反例反而得到
`quality=quote, spans=(("b2" 0 6))`。应在 quote fallback 前拒绝反向 canonical indexes，并补回归。

- **位置：** `epub-reader-locator.el:112-135,498-514`。
- **问题：** `range-from-plist` 只要求外层 schema=1；通用 locator decoder 只要求 schema 是整数，
  不保证 endpoint 为当前 schema 3。range resolver 又绕过 locator resolver，只读 endpoint 字段，
  因此不受支持的端点仍可成为 exact 高亮。
- **证据：** 把合法 range 的 start/end schema 都改成 999，decode 成功，随后 resolution=`exact`。
- **影响：** 损坏、未来版本或手工编辑的 sidecar 不会被可靠拒绝；同一份 endpoint 若当进度使用会
  报 unsupported，而当 annotation 使用却被接受，schema 契约前后不一致。
- **修复建议：** decode 要求 start/end schema 都为 3，并校验 book/path/spine identity 与 offset
  顺序；resolver 对内存构造值再做一次防御检查，返回 `unsupported-schema` 而非使用字段。

### S-01 — P1 应修：合法的 marks-only sidecar 在默认配置重开时丢失全部书签/标注

**复核结果：已解决。** `load-locator` 对缺失 `:locator` 直接返回 nil，进度损坏使用独立的
`progress-warning`，不再污染 marks 读取。原探针重开结果为 locator=nil、warning=nil、
bookmark=1、annotation=1；默认启用进度的 UI 重开回归亦通过。

- **位置：** `epub-reader-store.el:83-97,191-217`；`epub-reader-ui.el:2268-2281`。
- **问题：** schema 2 明确允许 book record 同时缺少 `:updated` 和 `:locator`，因此只保存 reader
  marks 是合法状态。但 `store-load-locator` 只检查 entry 存在，就对 nil 调
  `epub-reader-locator-from-plist`，把“没有进度”记成 store-wide warning。UI 默认启用进度并先加载
  locator，随后 `--load-items` 因 warning 直接返回 nil。
- **证据：** 新 sidecar 只写一条 bookmark；重开 store 后 locator=nil、warning 为
  `Invalid persisted EPUB locator: nil`、bookmarks=nil。磁盘数据仍在，但 UI 看起来像全部丢失。
- **影响：** 用户曾关闭进度保存、只做书签/高亮，之后恢复默认配置或换配置重开时，所有 marks 都
  不显示且不能继续保存。
- **修复建议：** entry 没有 `:locator` 时直接返回 nil，不设 warning；locator 单项损坏也应与
  bookmarks/annotations 的可读性隔离。补“progress disabled 创建 bookmark+annotation →
  progress enabled 重开”UI 回归。

### U-01 — P1 应修：隐藏后仍存活的书签/标注列表不会显示新条目

**复核结果：已解决。** 重新 display live buffer 前会 refresh 并按选中 id 恢复 point；reader 新增
bookmark/highlight 也会刷新 live secondary buffer。原两项列表反例均由 1 项更新为 2 项。

- **位置：** `epub-reader-ui.el:1884-1904,2184-2204`；新增命令
  `epub-reader-ui.el:1766-1786,1906-1929`。
- **问题：** `q` 只隐藏列表窗口，不 kill buffer。`epub-reader-bookmarks` 与
  `epub-reader-annotations` 遇到 live existing buffer 只 `display-buffer`，不 refresh；reader 中新增
  mark 也不通知列表。因此列表一旦打开，之后新增条目长期不可见。
- **证据：** 先添加 bookmark `one` 并打开列表，再在 reader 添加 `two`，重新按 `M`；session=2，
  list buffer 的唯一 bookmark id 仍只有 1 个。
- **影响：** 主流程“看列表 → 回书中继续标 → 再看列表”直接失效；用户没有包内命令可重建列表，
  只能手工 kill buffer 或碰巧执行会 refresh 的列表删除操作。
- **修复建议：** 重新 display existing list 前调用对应 refresh，并保存当前 item id/行；新增、删除、
  编辑时若 secondary buffer live，也刷新或标 dirty。bookmark 与 annotation 两条路径共用一个刷新协议。

### U-02 — P1 应修：未访问章节的 degraded 状态在列表里不可见，跳转后也不更新

**复核结果：已解决。** 列表生成时通过 locator API 对每项所在章节做 canonical resolve，未访问章
不再把 nil 当 exact；跳转后刷新选中项。原反例在跳转前后均显示 `⚠`，quality=`quote`。

- **位置：** `epub-reader-ui.el:871-896,1985-2037,2046-2101,2131-2139`；
  `epub-reader-annotation.el:25-29,74-96`。
- **问题：** `quality` 是未持久化的运行时字段，只在当前章节生成 frame 或执行跳转时解析。重开后
  未访问章节的 annotation quality 为 nil，列表却把 nil 当成无需警告；activate 把它更新为
  `quote` 并在 reader 显示 message/wave face，但没有 refresh 已打开的列表。
- **证据：** 构造 block-key 变化、quote 可恢复的第二章高亮；重开停在第一章时列表无 `⚠`。RET
  后 quality=`quote`，reader face 为 `epub-reader-highlight-degraded-face` 且 message 可见，原列表
  仍无 `⚠`。
- **影响：** README 所说“列表中的警告”在常见重开流程不成立；用户浏览列表时无法知道哪些高亮
  已经移动或失效。
- **修复建议：** 列表生成时按 chapter 复用 canonical locator index 计算状态，或明确显示“待验证”；
  activate 后 refresh 当前 item。不要简单持久化上一次 quality，因为 EPUB/renderer 变化后它会过期。

### T-01 — P2 建议：新增 fixture 与测试恰好绕过主要英文 range 风险

- **位置：** `test/fixtures-src/language-mix/EPUB/text/chapter.xhtml:1-9`；
  `test/epub-reader-annotation-test.el:87-223`；`test/epub-reader-ui-test.el:994-1163`；
  `test/epub-reader-store-test.el:610-675`。
- **问题：** fixture 在 ZIP/OPF/nav 形式上是真 EPUB，但内容只有一个短英文句和一个几乎无空格的
  中英句。range 回归选的是 `Emacs阅读EPUB`，不会跨英文折行空格；所谓 reflow 只 stub 宽度后手工
  refresh，没有调用 `text-scale-set`。UI 测试未覆盖 annotation list 的 activate/edit、存活列表
  refresh、未访问章节 degraded 警告；迁移测试只加 bookmark，未断言旧 progress 与 annotation
  同时保存。
- **真实样本差异：** Economist 有 95 个 spine；章节 18 的正文被当前 renderer 合成一个 9,476
  字符 block、无逻辑换行。54 列产生 183 个物理行，断词与非末行对齐通过，但第一个普通空格断点
  就复现 R-01。新增 fixture 没有覆盖这种现实 DOM/长段形状。
- **修复建议：** fixture 增加带空格的长 English 和 spaced mixed paragraph、重复 quote、多个
  publisher paragraph 容器；测试从实际相邻 physical lines 选区，不硬编码一个不会折行的 phrase。
  再补真实 `text-scale-set`、marks-only 默认配置重开、列表 stale/degraded 与 v1 三类数据共存。

### A-01 — P2 建议：每条标注都重复扁平化整章，range record 仍是脆弱五元 list

- **位置：** `epub-reader-ui.el:861-896`；`epub-reader-locator.el:429-469,498-551`。
- **问题：** UI 构造 `(BOOK-KEY SPINE-INDEX PATH BLOCK TEXT)` positional records；每次 render 又为
  每条 annotation 调一次 range resolver，而 resolver 每次重新生成整章 text 和逐字符 mapping。
  成本约为 `annotation-count × chapter-source-characters`，大章与大量高亮时会直接加到 resize、
  text-scale 和 chunk refresh 的交互延迟上。
- **修复建议：** locator 模块提供 typed canonical chapter index，一章一次构建 text、block/offset
  mapping、quote index，所有 ranges 复用。这样也为 R-01 的 canonical capture 提供正确接口，并
  消除 UI 对五元 list 字段序号的知识。

### D-01 — P2 建议：架构文档仍把已实现标注列为首版不支持

- **位置：** `docs/architecture.md:278-282,306,324`。
- **问题：** 模块清单没有 `epub-reader-annotation.el`，发布边界仍写“高亮、笔记、annotation UI
  不支持”，阶段说明仍称 annotation 要等 locator 稳定后再做。实现已经越过该边界，文档会误导后续
  审查和模块所有权判断。
- **修复建议：** 在 gate 修复后更新模块图、range/schema 版本、annotation domain/store/UI
  责任与本阶段验收；不要在 P0 尚未关闭时把当前能力写成已稳定完成。

## 通过项与边界

- frozen 0.1.0/schema 1 sidecar 经同一个 read/merge/write 锁事务升级为 schema 2，旧 progress、
  新 bookmark、新 annotation 可共存；写后无 canonical lock 残留。此前 S-04 原子发布/ABA 回归仍
  全绿，本阶段没有另开写路径。
- store-level 两 handle item merge 与 UI-level 两 reader 独立高亮均通过，删除 tombstone 也不抹掉
  另一 item。该结论不覆盖同一 annotation id 的同 timestamp 人工碰撞，但不构成现实 gate。
- `aaf4126` 的 image-slice 过滤有效：纯图片行不可建立 text highlight，包含图片行和可见 caption
  的选择只保存 caption 一次。合成 layout whitespace 被忽略这一原则本身正确；R-01 的问题是源
  空格也被排版层隐藏，不能与 synthetic cell 等同处理。
- 高亮 face 在所测 Leuven/Wombat 均强制浅黄背景和深色前景，计算对比度约 14.6:1；degraded
  wave underline 在 face 属性中存在。终端有限色映射未做图形像素验收，当前无证据判为缺陷。
- reader、TOC、bookmark list、annotation list 使用独立 minor-mode maps。`m/M/h/e/a` 没有覆盖
  reader 已有键；annotation list 的 `e` 与 reader 的“编辑笔记”语义一致，TOC/书签列表未绑定这些键。
- 生产模块仍只使用 TextUI public API；`test/epub-reader-annotation-test.el:33,106,158` 读取/替换
  TextUI 私有符号只作为测试观测 seam，应逐步用公共可观测结果替代，但不是生产架构违规。

## 最终 Gate

**不通过。** 当前未关闭计数为 **P0=0、P1=1、P2=3**。R-01、R-02、S-01、U-01、U-02 已关闭；
R-03 因跨 block 反向 endpoint 仍可静默错锚而保持部分解决。修复上述单一确定性反例后即可解除
标注阶段 gate；GUI-only 的两个既有 skipped 用例与三个 P2 不单独阻断。
