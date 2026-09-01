# 第三阶段聚焦审计

审计日期：2026-09-01

审计范围按“4 个提交”解释为包含首提交，固定 diff 为
`git diff ed49f17...e525eef`：

- `efead42`：惰性 EPUB member materialization；
- `c9845a2`：active chunk 内按需展开图片；
- `f9da5b5`：图片行距、二次软折行和 viewport 视觉行修复；
- `e525eef`：性能及 TextUI 集成问题文档。

规格基线为本轮五项审计要求、`docs/architecture.md:60-79,133-168`。初审完整执行
`./test/run-tests.sh`：**85/85 通过，0 unexpected**。另跑 archive 换包、跨调用累计、
同成员重入、CRC、partial、别名和 4 组 viewport 探针。

复核范围固定为 `git diff e525eef...b1c4b47`：`7383a01`（archive snapshot 与预算事务）、
`398e254`（图片行距与 text-scale）、`13b8ba6`（0.1.0 sidecar fixture）、`b1c4b47`
（显示限制文档）。复核再次完整执行 `./test/run-tests.sh`：**93/93 通过，0 unexpected**；另跑
换包、双 buffer 重入、结构/像素 line-spacing、batch 与图形 text-scale 探针。图形探针使用
GNU Emacs 31.0.91。

最终裁决轮固定 reader diff 为 `git diff 04d215a...23a2302`（`2bab027`、`23a2302`），并审查
TextUI 上游 `f6b3a06...0a89825`。本地重跑 reader **93/93**、当前 TextUI worktree
**109/109** 均通过；TextUI worktree 另有与图片无关的 focus/position 用户改动，本轮未修改或纳入
image diff 判断。另以 Emacs 31 图形帧重放 native CJK/locator/像素探针，并加 letterbox 与 combining
mark 反例。

## 结论先行

**Gate 仍不解除。** 最终修复关闭了 V-03 的“普通 CJK alt 写入 unibyte/属性全丢”主路径：fixture
可在 native GUI 渲染，3 个 anchor run、48 个 tagged row 与图片 locator 均存在。但 V-01 的核心
像素目标仍失败；V-03 也残留两个可构造的现实输入漏洞：letterboxed 图片从实际 slice 行而非 leaf
第 0 行开始 anchor，导致 caption 被误标；combining/variation 类 alt 可因字符数超过列槽触发
`args-out-of-range`。两套 ERT 全绿未覆盖这些边界。

| 严重级别 | 未关闭 | 已关闭 | Finding |
|---|---:|---:|---|
| P0 阻断 | 0 | 0 | 无 |
| P1 应修 | 2 | 3 | 未关闭：V-01、V-03；已关闭：C-01、C-02、V-02 |
| P2 建议 | 2 | 3 | 未关闭：D-01、D-02；已关闭：C-03、P-01、R-01 |

## 安全与并发探针摘要

| 目标 | 独立实测 | 判定 |
|---|---|---|
| 顺序累计上限 | bootstrap 后把总上限固定为当前 272 bytes，再取章节；报 `epub-reader-archive-limit`，counter 未变 | 通过 |
| 失败原子发布 | 上述失败后 final 不存在，`.part-*` 数为 0 | 通过 |
| 成员 CRC | 翻转 `chapter1.xhtml` 压缩数据；unzip/bsdtar 均报错，final 不存在，partial 为 0 | 通过，但只校验当前 archive |
| glob/casefold | `chapter*.xhtml` 为 unsafe；大小写别名 missing；glob/case-collision fixture 均在 open 拒绝 | 通过 |
| 同成员重入 | outer 成功且无 partial；第二 buffer 得到 `Recursive materialization` error | 文件安全，但未合并/等待赢家 |
| 不同成员重入 | 两成员均发布；`materialized-bytes=709`，实际缓存文件合计 `1253` | **失败：lost update** |
| open 后换包 | A preflight 后把源路径替换为同名、同 uncompressed size 的 B；读取结果不等于 A、等于 B | **失败：preflight 快照失效** |

复核探针把上面最后三行重新执行：换包现报 `epub-reader-archive-changed` 且 OPF final 不存在；
双 buffer 在 outer stream yield 时请求另一成员，第二 reservation 被累计上限拒绝，最终
`baseline=272, committed=709, limit=816, reserved=0`，counter 与缓存实际字节一致；同 key
返回独立的 transient `epub-reader-materialization-busy`，renderer 不再把它缓存为永久图片错误。

## Findings

### C-01 — P1 应修：lazy extraction 没有绑定 preflight 的 archive 快照

- **位置：** `epub-reader-container.el:86-95,244-370,568-571,590-607`；
  `epub-reader-publication.el:61-82`；`docs/architecture.md:64-69`。
- **问题：** container 保存的是外部 EPUB pathname。中央目录只在 open 时读取；后续每次
  materialize 都让 adapter 重新打开该可变 pathname。entry 甚至没有保存 central-directory CRC。
  因此 adapter 校验的是“当前 pathname 所指 ZIP 自己的 CRC”，不是 preflight 时那本书的 CRC。
- **证据：** 探针先用 A open/preflight，再用一个同名成员、相同 uncompressed size、内容不同的
  合法 B 覆盖源路径。`materialize-member` 无错误发布 B 的章节：
  `matches-preflight-book=nil matches-replacement-book=t`。publication 的 book-key 在 open 时已由
  A 的 path/mtime/content hash 固定，随后却可混入 B 的 DOM/图片；新 ZIP 的压缩比和 CRC 也未与
  A 的 metadata 绑定。
- **影响：** 同一次 session 可形成混合 publication，locator/store 身份与实际内容分离；同步器、
  下载器或同用户进程替换文件时即可发生，不需要破坏 reader 私有临时目录。
- **修复建议：** open 时创建只读私有 archive snapshot（同目录 clone/reflink 或 0600 copy），
  preflight、book fingerprint 和所有 adapter 调用都只读该 snapshot；不要只在每次调用前比较
  pathname 属性，因为检查与 child process open 之间仍有 TOCTOU。补“open 后原路径被同尺寸
  archive 替换”的回归。保存 central CRC 可改善诊断，但不能替代不可变 source。

**复核结果：已解决。** `epub-reader-container-open` 先复制 0600 私有 `.archive.epub`，preflight、
adapter 与 publication content hash 均读取该 snapshot；materialize 另校验外部 source identity，
使普通 rename replacement 明确失败。独立探针用同尺寸、同 mtime 的 B 原子替换 A，得到
`epub-reader-archive-changed`，未发布 OPF。检查到 adapter open 之间即使存在微小换包窗口，读取的
仍是私有 snapshot，不会再形成混合 publication；按本轮威胁模型记为可接受的非阻断残余。

### C-02 — P1 应修：并发 materialization 没有 container 级预算事务

- **位置：** `epub-reader-container.el:527-587`。
- **问题：** 每次调用在 `:561-562` 复制当前 `materialized-bytes` 到私有 cons，成功后在
  `:580-581` 覆盖写回。`accept-process-output` 会允许 timer/process callback 重入；不同成员可
  同时从同一旧值开始，最后写入者覆盖先完成者的累计值。同成员的 `materializing` flag 防止
  双发布，但第二个正常 caller 直接被当成“Recursive”错误，而不是复用/等待赢家。
- **证据：** 在 outer 的 stream seam 重入另一个 buffer：chapter2 先成功，chapter1 后成功；
  cache 实际为 1253 bytes，counter 仅 709。静态、metadata 诚实的 EPUB 仍受 open-time declared
  total 这一层保护，因此这不是单探针即可扩成无界 zip bomb；但“actual cumulative limit”状态
  已不可信，动态限额、错误 metadata/重试和今后的 archive snapshot 校验会受影响。图片层又把
  materialize error 缓存在 block（`epub-reader-render.el:632-659`），竞争 loser 可能永久显示错误。
- **修复建议：** 增加 per-container coordinator：在任何会 yield 的 stream 之前原子 reserve
  declared/actual budget；成功 commit、失败 release；不同 key 的累计更新不得 lost update。
  同 key 应复用完成结果，或返回可识别的 busy 状态并在赢家完成后重试，不能缓存为永久图片错误。
  若支持 Emacs threads，reservation/cache 状态还需 mutex 或单 worker 串行化。

**复核结果：已解决。** container 现在用 mutex 保护 `materialized`、`materializing`、
`materialized-bytes` 与 `reserved-bytes`，stream 前 reserve、实际字节超声明时 grow、成功 commit、
失败 cancel。双 buffer 确定性交错中 outer 先 reserve 437 bytes，contender 的 544-byte reservation
因累计投影超限而失败；outer 完成后 committed=709、reserved=0，counter 等于缓存文件合计且未越过
816-byte 上限。同 key loser 得到 transient busy，`epub-reader-render.el:667-671` 不再永久缓存。
当前测试用 event-loop reentry 而非 OS 线程，但真正的共享状态已在同一 mutex 事务内；剩余 close 与
materialize 的刻意跨线程交错不构成本轮现实 Gate。

### V-01 — P1 应修：line-spacing workaround 不是“只作用于图片行”

- **位置：** `epub-reader-ui.el:143-163,620-644`；
  `test/epub-reader-ui-test.el:147-170`。
- **问题：** post-render 的 `line-spacing=0` property 确实只标记带
  `epub-reader-image-slice` 的物理行；但 mode 启用时同时执行 `setq-local line-spacing nil`，
  清除了正文继承/用户设置的正行距。测试在 default 为 0.25 时反而断言整个 buffer 为 nil，固化了
  这个扩大作用域的 workaround。
- **证据：** 独立探针为 `default-line-spacing=0.25 buffer-line-spacing=nil`；普通 source 行没有
  property，仍因 buffer-local nil 丢失继承值。
- **修复建议：** 先验证各支持 Emacs 版本上整行 `line-spacing=0` property 的实际优先级；若仍
  不能压过 inherited spacing，应在 TextUI 增加公开的 image-row 行距/行高策略。reader 移除
  buffer 全局清零，并新增“图片行 effective spacing=0、普通正文仍为 0.25”的图形帧回归。

**复核结果：部分解决，仍阻 Gate。** mode 已移除 buffer-local 清零；结构探针得到
`buffer=0.25, local=nil, prose-property=nil`，所以非图片正文确实不受影响。但当前写入图片行的
`line-spacing=(0 . 0)` 不是可把 buffer 正行距压成零的可靠 newline text-property 形式。Emacs 31
图形像素探针在正行距 0.25 下得到 `image-height=17, prose-height=17, suppressed=nil`；93 项中的
测试只断言属性值存在，没有测实际像素高度。此外 native image 会丢失 anchor，真实图片行甚至没有
`epub-reader-image-slice`，见 V-03。应使用 Emacs 文档专为 image slices 给出的 newline
`line-height=t`（或经图形矩阵验证的等价公开契约），并补真实 graphical regression。

**最终复核：仍未解决。** `2bab027` 确实只给 tagged image row 的 newline 加 `line-height=t`，
buffer 继续继承 0.25，普通 prose newline 没有该 property；结构范围正确。但像素语义不成立：

- 最小图形探针中 image/prose 行均为 `17/17px`；
- 真实 native slice 同一行在继承 0.25 时为 17px，临时把 buffer `line-spacing` 设 nil 后为 14px。

原因是 buffer spacing 已由该行可见 glyph 累积；只改变 newline 的 line height 没有把整行已有的
extra spacing 清零。现有 ERT 仍只检查 `line-height=t` 属性存在。并且 V-03 的 letterbox 误标会把
该 property 加到 caption newline。必须找到可在图形 redisplay 中实际满足 `17 -> 14` 的公开方案，
并用“继承正行距 vs nil”的同一 native row 像素对照作为 Gate 测试。

### V-02 — P1 应修：text-scale 后不重排，图片度量也不跟随 face remap

- **位置：** `epub-reader-ui.el:143-163,764-838`；TextUI sibling checkout
  `textui.el:634-688,1492-1544`；`docs/textui-issues.md:19-34`。
- **问题：** reader 设置 `truncate-lines=t`，但没有 `text-scale-mode-hook`；TextUI 只在可见
  cell width 变化时 refresh。text-scale 改变字形像素宽度后，已有物理行仍按旧 scale 分行，超宽
  内容会从“二次 soft wrap”退化为被截断。即使手工 refresh，TextUI image slice 仍使用
  `frame-char-height`，不反映 buffer face-remap 的实际文本行高。
- **证据：** 对 `text-scale-set 2` 注入 refresh 计数得到 0。显式 `textui-refresh` 后，batch
  探针在 80/39 列、scale nil/2 四组都保持 locator 和 row（均 `4 -> 4`），说明
  `--restore-window-visual-row` 本身没有复现回归；但 `display-graphic-p=nil`，不能证明真实像素行高。
- **修复建议：** 与 TextUI 定义公开的 text-scale refresh/row-metric 契约，debounce full refresh
  并用 locator/view-state 恢复；image rows 应按目标 window/buffer 的实际字体行高计算。增加真实
  graphical Emacs 的窄/宽窗口 × scale 0/±2 矩阵，而不是只用 batch cell geometry。

**复核结果：已解决（reader-owned row budget）。** mode 新增 buffer-local
`text-scale-mode-hook`，完整 `textui-refresh` 前后捕获/恢复 locator 与 window view state；图片
`:rows` 按所有 live window 的 `window-font-height/frame-char-height` 取保守预算。独立 batch 探针将
font height 注入为 2 倍，生产图片物理行由 48 降为 24、refresh 恰好一次；Emacs 31 图形帧中实际
font height `14 -> 20`，四个 image block 的传入预算均由 `16 -> 12`，与公式一致。native image
的 source tag 缺失是另一条 V-03，不否定这里的重排/度量修复。

### V-03 — P1 应修：TextUI native image 丢 source property，并会被非 ASCII alt 击穿

- **位置：** `epub-reader-render.el:701-733`；`epub-reader-locator.el:383-414`；TextUI sibling
  `textui.el:634-688`。
- **问题：** reader 把 `epub-reader-image-anchor` 放在 `:image :alt` 字符串上，再依赖 post-render
  从 anchor 给每个图片行补 source/locator/line-spacing。非图形 fallback 会保留这些 property；
  native path 却用 `(make-string width ?\s)` 生成 unibyte 行，再以 `store-substring` 写 alt：CJK alt
  首先触发 `Attempt to store non-byte value into unibyte string`；即使探针把 alt 临时转成 ASCII，
  `store-substring` 也不复制源字符串的 text properties，所有 native 图片行仍无 anchor。
- **证据：** Emacs 31.0.91 图形帧直接进入 fixture 第二章即在 native image render 报上述错误；
  仅为隔离 V-02 而保留属性、ASCII 化 alt 后可完成重排，但实际 buffer 的 image tag 数仍为
  `0 -> 0`，而生产 leaf 预算为 `(16 16 16 16) -> (12 12 12 12)`。这也解释了 batch 的
  `epub-reader-ui-tags-every-rendered-image-row-with-source` 为何不能代表 GUI。
- **影响：** 含非 ASCII alt 的图片章节可能无法渲染；ASCII alt 即使可显示，图片 locator、进度、
  V-01 局部行距修复也失效。这是现实图形阅读路径，不属于微秒级理论竞态。
- **修复建议：** 优先修 TextUI 公共 `:image` 契约：native 行必须为 multibyte-safe，并保留 `:alt`
  的 text properties 到可识别的全部图片物理行；或提供公开 image-row metadata/post-render hook，
  避免 reader 借 alt 搬运 anchor。新增真正 `display-graphic-p=t` 的 ASCII/CJK alt × source round-trip
  × line-spacing 回归；生产代码继续不得调用 `textui--*` 私有 API。

**最终复核：部分解决，仍阻 Gate。** TextUI `0a89825` 把 native 行转为 multibyte，并用 concat
保留截断后 alt 的 properties。未注入 workaround 的 Emacs 31 GUI fixture 已能渲染“测试封面/图一/
图二”，得到 3 个 anchor line、48 个 image-slice row；中部图片行 locator 正确解析到
`OEBPS/chapter2.xhtml`。reader 生产代码仍未调用 `textui--*` 私有 API。这关闭了原始简单 CJK 主路径。

但两个独立反例仍失败：

1. **letterbox range：** TextUI 只在首个实际 slice（`row=top`）嵌入带 property 的 alt，reader 却从
   该行按配置 `rows` 向后标记。fixture 的小 SVG 产生 `top>0`，实际探针中 `[测试封面]` caption
   带 `epub-reader-image-slice=t`；顶部 padding 未覆盖、尾部越过 leaf。locator/line-height 作用域
   因此并不可靠。
2. **Unicode 字符数：** splice 用显示宽度截断 alt，却以 `(length alternative)` 切底层固定宽度行。
   `"a" + 20 个 U+0301` 的合法 alt 为 `chars=21, display-width=1`，在 10 列 native leaf 稳定报
   `args-out-of-range "          " 21 nil`。CJK variation selector/ZWJ 类序列同属此形态。

应把 anchor 固定在 image leaf 第 0 行或提供公开的精确 leaf range；splice 同时受显示宽度和可用字符
槽约束，并保留最终字符边界的 properties。补 letterbox+caption 与 combining/VS/ZWJ 回归后再关闭。

### C-03 — P2 建议：验证的是 private part，不是 rename 后 final truename

- **位置：** `epub-reader-container.el:464-477,555-576`；
  `docs/architecture.md:68`。
- **问题：** stream 后在 `:572-573` 验证 temporary truename，随后 rename 到 target，未对 final
  再验证。root 是 0700 私有目录，archive 也不能创建 symlink，因此普通恶意 EPUB 不能利用；但
  同用户进程若在 verify/rename 间替换父目录，严格的“materialize 后 final containment”仍有
  TOCTOU。
- **修复建议：** 发布后验证 final，且检查/固定 target 的父目录 identity；若要把同用户篡改纳入
  威胁模型，需要 directory-fd/openat 风格边界，单纯再做 pathname check 仍只是缩窗。

**复核结果：已解决。** rename 后现对 final 再执行 containment/truename 校验；若该检查或后续
commit 失败，unwind 会删除已发布 target 并释放 reservation。新增回归确认验证对象确为 final。
同用户进程若专门在 pathname 检查的微秒窗口篡改 0700 私有目录，仍只能靠 directory-fd/openat
彻底消除；按给定现实威胁模型接受为已知限制，不维持 Gate。

### P-01 — P2 建议：旧 sidecar 兼容成立，但没有冻结回归

- **位置：** `epub-reader-ui.el:321-326`；`epub-reader-publication.el:582-590`。
- **结论：** 有效 ZIP 的 central uncompressed size 与 materialized file size 相同；探针在
  EPUB2 两章得到 `(437=437, 544=544)`。本区间没有改 `epub-reader-store.el` 或
  `epub-reader-locator.el`，sidecar 保存的是 locator 而不是百分比，所以旧 sidecar 的恢复身份和
  位置不变；百分比只是以等价权重重新计算。**未发现语义不兼容。**
- **缺口/建议：** 新测试只断言 resource size，没有用 0.1.0 冻结 sidecar 重开并比较 locator、
  header percentage。应加入该 fixture；同时明确 malformed ZIP 的 central size 在 member 真正
  materialize 前只是声明值。

**复核结果：已解决。** `test/fixtures/v0.1.0-sidecar.el` 是字面旧 schema 内容，新测试从该文件
重开并断言 spine/path/block/offset、exact quality 与 44.5% header；完整回归通过。fixture 为可移植
性只替换 path-dependent `__BOOK_KEY__`，因此不单独冻结 fingerprint 算法；本区间 book-key 已改为
对等 snapshot bytes/保留 mtime 计算，另有 shared-identifier 身份测试，本 P2 不再维持。

### D-01 — P2 建议：TextUI 问题定性基本准确，但 workaround 影响写得不够完整

- **位置：** `docs/textui-issues.md:1-48`。
- **结论：** 两个根因与 sibling TextUI 源码吻合：`:image` 确按 `frame-char-height` 切片；生产
  代码没有调用 `textui--*`/`textui-kp-core--*` 私有 API，文档引用私有函数只是源码定位；满宽
  物理行再被 Emacs soft-wrap 的症状也合理。
- **不完整处：** 文档把 buffer-wide `line-spacing=nil` 描述成 workaround，却没有把“正文用户
  行距也被清除”列为代价；也没有列出 face-remap/text-scale 的 frame metric 缺口。
  `truncate-lines=t` 只阻止第二次折行，若 TextUI 产物实际超宽则会隐藏尾部内容，不应表述成宽度
  正确性修复。建议补三项限制及最小 graphical reproducer。

**复核结果：部分解决。** 文档已补正文继承、text-scale hook/row metric、variable-pitch 与长 token
截断限制，原三项缺口已覆盖；但它错误宣称 `(0 . 0)` 能稳定覆盖正行距，且未记录 V-03 的 native
image unibyte/property-loss。待 V-01/V-03 修复后必须同步改正文档与最小图形复现。

**最终复核：仍为部分解决。** `23a2302` 已准确记录原 native CJK/unibyte/property-loss 根因和
TextUI `0a89825`，但又把 newline `line-height=t` 描述成会忽略继承正行距；上述像素探针反证该结论。
文档也未写 letterbox anchor range 与 combining/VS 长字符序列限制，需随 V-01/V-03 再修订。

### R-01 — P2 建议：图片状态已形成位置参数 data clump

- **位置：** `epub-reader-render.el:417-459`。
- **问题：** local `emit` 连续接收六个 optional 图片/列表参数，调用出现
  `path nil href nil alt image-error`，属于 Data Clumps/Primitive Obsession judgement call，后续
  加图片尺寸或 media-type 时容易错位。
- **修复建议：** 使用 keyword 参数或小型 image metadata struct；不影响本轮 Gate。

**复核结果：已解决。** 新增 `epub-reader-render-image` 小结构，local `emit` 改为 keyword
`:level/:image/:list-marker`；原 `path nil href nil alt ...` 位置参数串已消失。

### D-02 — P2 建议：snapshot I/O 后仍沿用旧打开性能数据

- **位置：** `docs/perf-notes.md:15-23`；`CHANGELOG.md:19-22`。
- **问题：** C-01 让 `container-open` 新增整包 `copy-file`，但性能记录仍把修复前的 0.351302 秒、
  “按需 materialize 6 个成员”当作当前 HEAD 数据。成员落盘数仍可为 6，但 31.9MB archive snapshot
  的 I/O 已进入打开路径，旧的 69.6%/3.29 倍结论不能直接外推。
- **修复建议：** 在同一机器、同一样书重跑 5 次，单列 snapshot copy/preflight/首帧耗时；在新数据
  前把该表标为 `e525eef` 基线。此项是文档/性能可信度 P2，不单独阻 Gate。

## 视觉探针

| 场景 | window width | scale | visual row | locator |
|---|---:|---:|---|---|
| wide | 80 | default | `4 -> 4` | block/offset 不变 |
| narrow | 39 | default | `4 -> 4` | block/offset 不变 |
| wide | 80 | 2 | `4 -> 4` | block/offset 不变 |
| narrow | 39 | 2 | `4 -> 4` | block/offset 不变 |

这四组在非图形 batch frame 中、显式 full refresh 后通过，证明新增的逐行校正 loop 在 cell
geometry 下有效；它不能替代图形帧的 variable-pitch、line-spacing 和 face-remap 验证。

复核新增结果：

| 探针 | 环境 | 结果 | 判定 |
|---|---|---|---|
| 正文行距范围 | batch，default `0.25` | buffer 继承 0.25、非 local；prose 无 property | 通过 |
| 图片行 effective spacing | Emacs 31 GUI，default `0.25` | image/prose 均 17px，`suppressed=nil` | **失败（V-01）** |
| text-scale 生产重排 | batch，注入 2× font height | refresh 1 次，tagged image lines `48 -> 24` | 通过 |
| text-scale 实际度量 | Emacs 31 GUI，scale 0→2 | font `14 -> 20`，leaf budgets 每项 `16 -> 12` | 通过（V-02） |
| native CJK alt | Emacs 31 GUI | `Attempt to store non-byte value into unibyte string` | **失败（V-03）** |
| native source tag | Emacs 31 GUI，探针仅 ASCII 化 alt | image tags `0 -> 0` | **失败（V-03）** |

最终裁决轮：

| 探针 | 结果 | 判定 |
|---|---|---|
| native fixture CJK + property | 直接渲染成功；3 anchor lines、48 tagged rows | 主路径通过 |
| native image locator | 中部 tagged row → `OEBPS/chapter2.xhtml` image block | 主路径通过 |
| V-01 同一 native row | inherited 0.25=`17px`，buffer nil=`14px` | **失败** |
| V-01 最小 newline `line-height=t` | image/prose=`17/17px` | **失败** |
| letterboxed image range | `[测试封面]` caption 被标 `image-slice=t` | **失败** |
| combining alt | chars=21、display width=1、10 列 → `args-out-of-range` | **失败** |

## 测试质量

当前 93 项已经新增 source replacement、different/same key reentry、累计 reservation、final
containment、transient image busy、冻结 sidecar、正文/property scope 与 text-scale row budget 回归；
初审所列生产路径缺口大部分已关闭。剩余关键问题是测试全在 `display-graphic-p=nil`：

- line-spacing 测试只看 `(0 . 0)` 属性值，不验证像素行距是否真的下降；
- source-property/image-row 测试走 fallback，不走 `textui--render-image-spec` native 分支；
- text-scale 测试 mock `window-font-height`，能证明 reader 预算公式，却不能发现 native alt 的
  unibyte/property-loss；
- frozen sidecar 会注入当前 `book-key`，可冻结 schema/locator/percentage，但不能独立冻结旧
  fingerprint 算法。

因此“93/93”不能关闭 V-01/V-03；至少要有一个真实图形 Emacs job，覆盖 ASCII/CJK alt、source
round-trip、line-spacing 像素高度与 scale 0/±2。

最终轮 reader 93/93、TextUI 109/109 再次全绿。新增 reader test 仍只验证 image newline 上存在
`line-height=t`；新增 TextUI test 只覆盖普通“中文图注”且只要求 property 在某处出现。真实杂志
smoke 证明常见大图主路径，但不能覆盖小图 `top>0` 的 range 语义、buffer spacing 的像素差异，或
字符数远大于显示宽度的 Unicode 序列。这正是上述反例能穿过两套测试的原因。

## Standards

- **Medium（hard violation）：** `epub-reader-ui.el:663-667`、`docs/textui-issues.md:23-30`：
  `(0 . 0)` 没有兑现“图片行清零、正文继承”的文档契约；图形验证也证明图片行没有缩短。改用
  newline `line-height=t` 或经像素测试验证的公开方案。
- **Medium（hard violation）：** `docs/perf-notes.md:15-23`、`CHANGELOG.md:19-22`：新增整包
  snapshot copy 后仍沿用修复前 0.351 秒数据；需重测并单列 snapshot I/O。
- **Low（judgement call，Feature Envy）：** `epub-reader-render.el:667-671` 直接识别 container busy
  condition，泄漏 publication seam；可由 publication 转译成资源层 transient error。
- 其余 C-01/C-02/V-02 留在所属模块，生产代码仍只使用 TextUI 公共 API。

最终裁决轮（`04d215a...HEAD` + TextUI `f6b3a06...0a89825`）：

- **High（hard violation）：** TextUI `textui.el:675-686` 只覆盖普通 CJK；
  `truncate-string-to-width` 限制显示宽度而不限制字符数，combining/variation selector alt 可令
  `(substring line (+ left (length alternative)))` 越界。修复为“显示宽度 + 可用字符槽”双限、
  属性保真的 splice，并补 combining/ZWJ 回归。
- 其余静态规范未发现新增违反：reader 的 newline `line-height=t` 写法符合 Emacs documented form，
  正文变量未覆盖，生产代码仍只用 TextUI 公共 API；但其实际像素效果由独立探针判定失败。

## Spec

- **Medium：** V-01/D-01 只部分完成：正文继承已恢复，但图片行 effective spacing 未清零，文档
  又把未经像素验证的 `(0 . 0)` 写成稳定方案。图形探针进一步发现 V-03。
- **Low：** C-02 回归主要是单线程 event-loop reentry，缺真实 thread job；P-01 fixture 注入当前
  book-key，不能单独发现旧/新 fingerprint 漂移。这两项不推翻生产事务/sidecar 恢复结论。
- C-01、V-02、C-03、R-01 满足原规格；没有明显 scope creep。

最终裁决轮：

- **High：** V-03/V-01 仍部分解决。TextUI 只把 anchor 放在首个实际 slice 行 `top`，reader 从该行
  按配置 `rows` 向后标记；宽扁图会漏顶部 padding 并误标 caption/后续内容，随后 V-01 也把
  `line-height=t` 加到错误 newline。应让 native/fallback anchor 都固定到 leaf 第 0 行，或公开精确
  leaf range，并加 letterbox + 后续正文 GUI 回归。
- **Medium：** V-03 的 multibyte-safe 不完整；combining/ZWJ alt 的字符数可大于列数并击穿 splice。
- 普通 CJK alt/property、documented `line-height=t` 形式、无 reader 私有 API 均已实现；无 scope creep。

双轴摘要：Standards 3 个 finding，最严重为 V-01 文档/实现契约不成立与性能基线过时；Spec 2 个
finding，最严重为 V-01/D-01 只部分完成。独立图形探针另新增 V-03 P1。

最终双轴摘要：Standards 1 个 finding，最严重为 Unicode alt splice 越界；Spec 2 个 finding，
最严重为 letterbox range 污染 locator/line-height。独立像素探针另确认 V-01 effective spacing 未关闭。

## Gate 结论

**Gate 不解除，第三阶段仍不可视为完成。** 常见 CJK native image/locator 冒烟已经从失败变为
通过，值得保留；但不能据此关闭两个 P1。剩余 Gate 条件都是可重复的现实显示/Unicode输入，不属于
同用户微秒级理论竞态：

1. V-01：在继承正 `line-spacing` 下，同一 native image row 的像素高度必须与 buffer spacing=nil
   相同；目前是 `17 != 14`。
2. V-03 range：letterboxed image 的 source/image-slice/line-height 必须严格落在 leaf 行内，caption
   与后续 prose 不得被覆盖。
3. V-03 Unicode：combining/VS/ZWJ alt 不得越界，CJK alt 的 properties/locator 仍须 round-trip。

D-01/D-02 仍是非阻断文档 P2。完成上述三个回归并重跑真实 graphical fixture 后，才可解除 Gate。
