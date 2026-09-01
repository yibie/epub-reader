# 第一阶段代码对抗性审计

审计日期：2026-08-31

审计对象：`epub-reader-container.el`、`epub-reader-publication.el`、
`epub-reader-render.el`、`epub-reader-locator.el`、`epub-reader-ui.el`、
`test/`、`test/fixtures*`，并以 `docs/architecture.md` 为蓝图。

## 结论先行（收尾复核更新）

**Gate 已解除，可以进入第二阶段。** 最后两项阻断均已关闭：P-02 现在对
literal 与 percent-encoded dot-segment 生成相同的远程 `resource-key`；L-02 现在由
identifier、规范路径、size/mtime 和 content hash 生成生产 `book-key`，不再只信
publisher identifier。

收尾复核基线为 `c0627f0...e9441ed`（`1e61cd9`、`e9441ed` 两个修复提交）。执行
`./test/run-tests.sh`：**45/45 通过，0 unexpected**。

| P0/P1 复核状态 | 数量 | 说明 |
|---|---:|---|
| 已解决 | 14 | A-01、A-02、A-03、A-04、P-01、P-02、P-03、P-04、L-01、L-02、R-01、R-02、T-01、X-01 |
| 部分解决 | 0 | 无 |
| 未解决 | 0 | 无 |

### 第二轮指定探针复测

| 探针 | 复测结果 |
|---|---|
| root-relative OCF URL | `/EPUB/text/a.xhtml` 与对应 EPUB fixture 均被拒绝 |
| OCF 禁止字符/full fold | PUA、noncharacter、Specials 的全部边界被拒绝；`ſ/s`、`ς/σ`、`ẞ/ss`、`İ/i̇`、`ﬃ/ffi` 均碰撞 |
| 真实 TextUI chrome 区域 | 1,318 个 chrome 字符中产生 locator 的数量为 0；章首/章尾无漏标 |
| exact quote / 同段多图 | 前插 `XX ` 后以 `quote-near-block` 恢复到新 offset 10；3 张图的 3 个 key 全部唯一 |
| `zh` segment break | `中\n文`/`中文\n，继续` 无空格；`ko/en/nil` 保留分词空格，inline `lang` 可覆写继承语言 |
| 远程 URL dot-segment（收尾探针） | canonical、literal `/a/../audio.mp3`、encoded `/a/%2e%2E/audio.mp3` 的 `resource-key` 均为 `https://example.com/audio.mp3` |
| 生产 book identity（收尾探针） | 两个真实 fixture 的 identifier 同为 `urn:fixture:shared-identifier`，生产 `book-key` 分别为不同 SHA-256 fingerprint |

## 规范基线与复现方法

规范对照采用 [EPUB 3.3](https://www.w3.org/TR/epub-33/)、
[EPUB Reading Systems 3.3](https://www.w3.org/TR/epub-rs-33/) 和
[CSS Text 3 的空白处理](https://www.w3.org/TR/css-text-3/#line-break-transform)。
与本审计直接有关的规则包括：

- OCF 文件名限制长度和危险字符，同目录名称在 Unicode 规范化加 full case folding 后必须唯一；
- OCF URL 要按 URL parser 相对 container root 解析，不能把百分号解码简单等同于文件路径解码；
- `rootfile@media-type`、manifest `item@media-type` 必填，manifest URL 在解析后必须唯一；
- package 的 `unique-identifier` 指向特定的 `dc:identifier`，不是“取第一个 identifier”；
- manifest 可以列出远程 publication resource；不自动联网不等于拒绝整本书；
- EPUB 3 nav 的 `li` 可以是 `span` 分组标题后接子 `ol`；
- `file:` URL 被 EPUB 3.3 明确禁止，`data:` 也不能作为普通顶层超链接；
- `linear="no"` 在默认遍历中是“可以跳过”，不是“必须跳过”。因此当前保留并经过
  non-linear item 不是本报告的规范 finding。

以下是初审时的历史基线：当时执行 `./test/run-tests.sh` 为 16/16 通过，
0 unexpected；四组定向探针当时的失败如下，本次复测结果见文首：

| 探针 | 实际结果 |
|---|---|
| ZIP 内有 `a*`（1 byte）和 `abc`（2 bytes），按条目 `a*` 读取 | `unzip`、`bsdtar` 都返回 3 bytes，证明参数按 glob 匹配 |
| `--split-href "a%2Fb.xhtml"` | 得到 `a/b.xhtml`，编码分隔符被错误升级为目录分隔符 |
| locator 位于 10 个合成换行中、距前块 2 字符且距后块 9 字符 | 返回后块，所谓“nearest”并不取最近距离 |
| `中\n文` / `中文\n，继续` / `<br>` | `中 文` / `中文 ，继续` / 普通空格 |

## Findings

### A-01 — P0 阻断：大小限制发生在完整解压并复制之后

- **位置：** `epub-reader-container.el:69-85,138-178`；蓝图
  `docs/architecture.md:64-70`。
- **问题：** `process-file` 先把 `unzip -p`/`bsdtar -xOf` 的全部 stdout 写进
  Emacs 临时 buffer，`buffer-string` 又复制一次；随后才在 `:165-174` 计算长度并比较
  64 MiB/512 MiB 上限。一个声明或实际展开为数 GiB 的高压缩条目会在检查前占满内存，
  因而当前“大小限制”不是安全边界。子进程也没有超时或可取消的输出上限。
- **修复建议：** 先从中央目录做条目数、声明压缩/解压大小和压缩比 preflight，但把元数据
  仍视为不可信；实际读取改为异步 process/filter 流式写入，累计达到
  `max-entry/max-total` 立即 kill 子进程并删除 partial file；增加 wall-clock timeout。
  回归测试用很小的动态上限验证只多读一个 bounded chunk，而不是先 materialize 全量。

- **复核结果：已解决。** `epub-reader-container.el:361-440` 以
  `make-process :buffer nil` 输出到 filter，在 `:397-408` 先检查条目/总实际字节，
  再于 `:409-412` 追加目标文件，超时在 `:413-419` kill 子进程，失败删
  partial file（`:439-440`）。`test/epub-reader-container-test.el:122-144` 对两
  adapter 伪造假元数据；独立 64-byte 探针实测两者均在 4096-byte 输出完成前
  报限额，且无 partial file。内存峰值只受单个 process chunk 影响，不再随 entry 大小增长。

### A-02 — P1 应修：清单本身无界，目录数和压缩比限制可绕过

- **位置：** `epub-reader-container.el:87-97,120-136`；蓝图
  `docs/architecture.md:66-68`。
- **问题：** `-Z1/-tf` 的完整输出先进入字符串再 `split-string`；文件数检查之后才发生。
  `file-count` 只统计非目录条目，任意多的目录项可绕过 10,000 限制并触发大量
  `make-directory`。代码完全没有压缩比、清单 byte 数、总条目数、路径 byte 长度或
  子进程时间限制；也只检查 mimetype 内容，未检查 OCF 要求的首条、stored、无 extra field。
- **修复建议：** 给中央目录解析设置输出 byte/条目/目录/时间上限，目录也计入总 entry 数；
  校验声明 size 与 ratio 并以 A-01 的实际流量上限兜底；同时验证 OCF `mimetype` ZIP 元数据。

- **复核结果：已解决。** 不再调用 archive tool 生成无界清单；
  `epub-reader-container.el:222-293` 先从 EOCD 读有界中央目录，`:241-246`
  在读入前限制 entry 数和 central-directory bytes。`:316-348` 分别限制文件、
  目录、声明总量和 ratio，`:295-314` 检查 `mimetype` 为首条、stored、无 local
  extra field。`container-test.el:94-120` 覆盖目录数、central bytes、条目大小与
  ratio；timeout/坏 mimetype metadata 尚无专门回归，该测试债归入 T-01，不改变本项代码结论。

### A-03 — P1 应修：成员名被当成 glob，列表条目与读取字节失去一一对应

- **位置：** `epub-reader-container.el:103-117,138-146`。
- **问题：** validator 接受 `*`、`?`、`[` 等字符，随后把成员名直接作为 archive tool 的
  pattern 参数。定向 ZIP 中请求 1-byte 的 `a*`，两个 adapter 均拼接返回 `a*` 与 `abc`
  共 3 bytes。攻击者可令一个已验证名称选择多个成员，破坏逐条大小、内容身份和总量核算。
  OCF 本来禁止 `*`、`?` 等字符，但当前没有实现这层拒绝。
- **修复建议：** MVP 最简单可靠的策略是完整拒绝 OCF 禁止字符，并为每个 adapter 使用
  literal member 选择能力；如果工具没有可靠 literal 模式，不要用 member pattern API，
  应改用已验证的中央目录/流式 extractor。两个 adapter 都补 `* ? [ ]` 恶意 fixture。

- **复核结果：已解决。** `epub-reader-container.el:175-203` 在 adapter
  调用前拒绝 `* ? [ ]`（以及其他已知 adapter metacharacter）。
  `container-test.el:77-82` 对 `glob-member.epub` 参数化两 adapter；原 `a*`
  探针现均在 preflight 报 `epub-reader-unsafe-archive`，不再发生 1 byte 声明对应
  3 bytes 输出的身份混淆。

### A-04 — P1 应修：raw-string 去重挡不住规范化/大小写路径碰撞

- **位置：** `epub-reader-container.el:103-136,148-178`。
- **问题：** `seen` 只按 `equal` 比较 ZIP 原始名字。`A.xhtml/a.xhtml`、NFC/NFD 等在
  case-insensitive 或 normalization-insensitive 文件系统可落到同一 target，后条目静默覆盖
  前条目；代码还接受 OCF 禁止的引号、冒号、尾点、C0/C1 等名字。EPUB 规范明确要求同目录
  名称在 canonical normalization + full case folding 后唯一，不能把宿主文件系统的行为当保护。
- **修复建议：** 分目录建立规范化 case-fold key 并拒绝碰撞；实现 OCF 文件名/路径 byte
  长度与字符约束；写入前后都验证目标仍属于专属 root，并测试大小写、NFC/NFD 和尾点碰撞。

- **复核结果：部分解决。** `epub-reader-container.el:165-203,316-348`
  已做 NFC 与大小写 key、路径/分量 byte 上限和大部分禁止字符，`:442-468`
  也在 materialize 前后检查 containment。`container-test.el:84-92` 只锁定
  `A/a` 和 `É/é`。扩展探针显示 U+E000（PUA）、U+FDD0（noncharacter）、
  U+FFF9 仍被接受；`long s` U+017F 与 `s` 的 canonical key 仍不相等。即 OCF
  禁止字符集和规范要求的 full case folding 都未完整实现。应以 Unicode
  Default Caseless Matching/full fold 生成 key，补 PUA/noncharacter 区间及 `ſ/s`、`ς/σ`等回归。

- **最终复核结果：已解决。** `epub-reader-container.el:165-225` 现覆盖
  BMP/补充平面 PUA、surrogate、U+FDD0–FDEF、Specials 与每个平面的末两个
  noncharacter，并以 full fold 生成 canonical key。独立探针复测所有禁止区间
  边界都被拒绝；`ſ/s`、`ς/σ`、`ẞ/ss`、`İ/i̇`、`ﬃ/ffi` 均生成相同 key。
  `test/epub-reader-container-test.el:84-121` 还用真 ZIP 覆盖 full-fold collision 和 PUA。

### A-05 — P2 建议：正常 cleanup 可用，但失败后不可重试且少一次 containment 复核

- **位置：** `epub-reader-container.el:182-216`；蓝图
  `docs/architecture.md:68-70`。
- **问题：** open 的 `unwind-protect` 和 buffer cleanup 在正常错误/kill-buffer 路径确实有效，
  当前按 stdout 写普通文件也不会 materialize ZIP symlink，这是正面结果。但 `close` 在
  `delete-directory` 成功前先设 `closed-p=t`；删除失败时句柄已不可重试。清理异常还会覆盖原始
  打开异常；蓝图要求的 materialize 后 `file-truename` containment 没有执行。
- **修复建议：** 删除成功后再置 closed，或保留可重试状态；cleanup error 作为附加诊断而非
  覆盖主错误；逐文件写完后做 truename containment，并考虑下次启动清扫带本包标记的孤儿目录。

### P-01 — P1 应修：href 实现不是 URL parser，percent-encoding 语义错误

- **位置：** `epub-reader-publication.el:125-185`；蓝图
  `docs/architecture.md:74-79`。
- **问题：** 代码先对整个 path `url-unhex-string`，再按 `/` 做文件路径归一化。因此 `%2F`
  变成真实目录分隔符，`%5C` 变成反斜线并被当攻击拒绝；这与 URL path segment 语义不等价。
  `%ZZ` 被原样接受，非法 UTF-8 `%FF` 也未报错。好的一面是 `%2e%2e` 解码后会经过 `..`
  检查，但这只覆盖了一个 case。架构中的“先 percent-decode/规范化”表述本身过度简化，不能
  作为当前算法正确的依据。
- **修复建议：** 以 OCF container root 和 WHATWG URL parsing 规则建一个深的 resolver；
  至少先严格验证 `%HH` 与 UTF-8，在 URL 分段完成前保留 encoded reserved delimiter，区分
  URL serialization 与 archive path。测试 `%20/%23/%2F/%5C/%2e/%ZZ/%FF`、Unicode fragment、
  query、空 path、过 root 和 HTML `base`。

- **复核结果：部分解决。** `epub-reader-publication.el:164-315` 已改为
  strict percent/UTF-8 decoder，按 segment 处理后才规范路径，对 `%2F/%5C` 保留编码分隔符。
  `publication-test.el:80-121` 与原探针证明 `%2F`、`%ZZ`、`%FF`、Unicode fragment、
  query、`base` 和过 root 均按预期处理。但 `--normalize-url-path` 在 `:271-281`
  特意接受以 `/` 开头的 URL；探针 `/%45PUB/text/a%20b.xhtml` 被静默解析成
  `EPUB/text/a b.xhtml`，而 OCF 文档中的 container URL 不得以 `/` 开头。
  resolver 因此仍不能作为 OPF/container 边界的完整 URL validator；需区分 OCF URL
  与正文超链接策略，并补 root-relative 回归。

- **最终复核结果：已解决。** `epub-reader-publication.el:312-367` 在解析
  local OCF URL 之前拒绝前导 `/`，且保留上轮已通过的 `%2F/%5C`、坏 percent/
  UTF-8、fragment、query、`base` 和过 root 行为。独立探针与
  `epub3-root-relative.epub` 均得到 `epub-reader-publication-error`；
  `test/epub-reader-publication-test.el:80-123,137-145` 已锁定该路径。

### P-02 — P1 应修：OCF/OPF 结构、namespace 与 required 字段校验不足

- **位置：** `epub-reader-publication.el:51-96,193-248,390-426`。
- **问题：** `xml-parse-region` 未启用 namespace 解析，所有节点/属性只按 local name 匹配；
  外来 namespace 的 `title/type/rootfile` 可抢先被采用。container 中取“任意后代的第一个
  rootfile”，不验证它是 `rootfiles` 的直接孩子或 `media-type=application/oebps-package+xml`。
  manifest 没有要求必填 `media-type`，也不检查 URL 解析后的唯一性；identifier 取第一个同名
  后代，忽略 `package@unique-identifier`。这些都直接违背 EPUB 3.3 的数据模型。
- **修复建议：** 用 `xml-parse-region` 的 namespace 模式并以 `{URI}local-name` 匹配；按规范
  直接子节点解析 container/package；验证 rootfile media type、package version、manifest
  required 属性/解析后 URL 唯一性、非空 spine；按 `unique-identifier` IDREF 选择标识符。
  对多 rendition 明确 deterministic policy 或报可理解的 unsupported 错误。

- **复核结果：部分解决。** `epub-reader-publication.el:149-162,323-477`
  已按 namespace 和直接子节点解析，并验证 rootfile media type、local manifest URL
  唯一、`unique-identifier`、media type 和非空 spine；`publication-test.el:123-146`
  覆盖其中的主路径。但仍有三个可复现的规范漏洞：`:317-321` 把空字符串
  required attribute 当作存在；`:646` 的 version regex 接受 `3.bad` 和 `2.`；
  external URL 在 `:301-302` 不分离 fragment，使 manifest 的
  `https://example.test/a#frag` 在 `:416-418` 检查中显示 `fragment=nil`而漏过。
  新测试没有覆盖这三条。修复时还应对远程 manifest URL 做解析后唯一性，
  而不是当前 `:413-415` 的 raw URI key。

- **最终复核结果：部分解决。** 空 required attribute、非 `2.0/3.0`
  version 和 remote fragment 已分别在 `epub-reader-publication.el:369-377,700-706,283-310`
  被拒绝；host 大小写、默认端口和 unreserved percent escape 也进入规范 `resource-key`。
  但这仍不是完整 URL parsing：`url-generic-parse-url`/`url-recreate-url` 不会移除
  dot-segment。探针得到 `https://example.com/a/../b` 与 `https://example.com/b`
  的 key 不等，`%2e%2e` 也只被解码成未归约的 `/../`。
  `test/epub-reader-publication-test.el:147-161` 只测 host/default-port/`%2E`，使等价
  remote manifest URL 仍可绕过 `:469-481` 的唯一性检查。应在生成 key 前完成
  URL path dot-segment normalization，并加真实重复 manifest fixture。

- **收尾复核结果：已解决。** `epub-reader-publication.el:306-368` 在 percent
  canonicalization 后按 RFC 3986 移除 dot-segment，再以结果生成 `resource-key`。
  独立探针确认 canonical、literal `..` 与 percent-encoded `..` 三者 key 完全相同；
  `test/epub-reader-publication-test.el:163-198` 还用两个真实重复 manifest fixture
  锁定直接 resolver 等价性和清单唯一性拒绝路径。

### P-03 — P1 应修：合法的远程 manifest resource 会使整本 EPUB 打不开

- **位置：** `epub-reader-publication.el:220-247`。
- **问题：** 每个 manifest href 无条件进入本地 `--normalize-path`；`https:` 会命中 drive/scheme
  检查并 signal。EPUB 3.3 允许 manifest 列出远程 publication resource，例如章节嵌入的远程
  audio。即使该资源不在 spine、也不需要当前 reader 获取，整本书仍会在 open 阶段失败。
- **修复建议：** resource model 区分 container URL 与 remote URL；解析并记录远程资源但默认
  不联网，只有实际渲染需要时才走明确的 capability/fallback/错误路径。测试“远程非 spine
  资源不妨碍本地正文”和 unsupported spine resource 的 fallback/诊断。

- **复核结果：已解决。** resource model 已增加 `uri/remote-p`
  (`epub-reader-publication.el:25-28,410-435`)；远程非 spine 只记录 URI，不网络请求，
  远程 spine 在 `:457-460` 返回明确 unsupported 错误。
  `publication-test.el:135-146` 同时锁定两条路径。远程 URL 的 fragment/唯一性校验债
  记在 P-02，不再是“合法 remote item 令整书打不开”的本项故障。

### P-04 — P1 应修：EPUB 3 `span + ol` TOC 分组被整棵丢弃

- **位置：** `epub-reader-publication.el:328-348`。
- **问题：** `label-node` 可以是 `span`，但创建 entry 又要求 `target` 非 nil；span 没有 href，
  所以合法的分组节点和所有 nested `li` 一起返回 nil。当前 fixture 只有两条 flat `a`，没有触发。
- **修复建议：** TOC entry 允许 target=nil 的 group，保留 children；或者显式 flatten children，
  但不能丢树。补 `span -> ol -> a`、多层 `a -> ol`、alt/title label 和 percent fragment fixture。

- **复核结果：已解决。** `epub-reader-publication.el:540-581` 允许
  `target=nil` 但有 children 的 `span` group，并保留嵌套 `a/span -> ol -> li`；label
  也会 fallback 到 `title`/图片 `alt`。`publication-test.el:148-159` 在真实 nav
  fixture 上检查三层树、group 无 target 和 Unicode fragment。

### P-05 — P2 建议：所有 scheme 都直接交给 `browse-url`

- **位置：** `epub-reader-publication.el:140-143,169-185`；
  `epub-reader-ui.el:211-243`。
- **问题：** `file:`、`data:`、`javascript:` 和用户自定义 scheme 都被标成 external，并在用户
  按 RET 后无提示交给 `browse-url`。EPUB 3.3 明令禁止 file URL，并限制 data 顶层链接；未知
  scheme 还可能触发用户自定义 handler。虽需用户激活，仍不应信任书内内容决定本机 handler。
- **修复建议：** 明确 allowlist（通常 `https/http`，按策略支持 `mailto`），拒绝
  `file/data/javascript`，未知 scheme 先显示 URI 并确认；测试 UI 外链路径且不真实启动浏览器。

### L-01 — P1 应修：合成空白的选择顺序不等于“最近 source”

- **位置：** `epub-reader-locator.el:46-66`；蓝图
  `docs/architecture.md:225-230`。
- **问题：** 当前位置和前一字符无 source 时，函数先选下一个 property change，最后才看前一个；
  没有比较距离，也没有限制同一视觉邻域。实测在 10 个合成换行的第 2 个位置，前块距离 2、
  后块距离 9，却返回后块。边框、padding、header/footer 上还可能跨 block 甚至跨 UI 区域吸附。
- **修复建议：** 同时找前后 source，按 buffer/visual row 距离和 block boundary 比较；对 frame
  chrome 返回 nil，而不是任意吸附。定义 tie-break，并补 newline、U+200B、padding、border、
  章首章尾的表驱动测试。

- **复核结果：部分解决。** `epub-reader-locator.el:62-132` 已同时找
  前后 source，用 row/character 真实距离比较，设置最大距离并在 tie 时选前块。
  `render-test.el:115-131` 使原“10 个合成换行”探针通过，并覆盖 U+200B。
  但 chrome 只在当前字符自身带 `epub-reader-chrome` 时被拒绝（`:113-117`）；
  TextUI 在 header 周围生成的 row/gap/padding 字符没有该属性。在真实 reader
  buffer 扫描章首到首个 source 之间，有 **64** 个无 source、无 chrome 属性的合成
  字符（position 98–161）仍会生成正文 locator。`ui-test.el:92-99` 只选中一个
  显式带 chrome 属性的字符，没有覆盖这个洞。需以区域/边界标记整段 UI chrome，
  而不是只查 point property。

- **最终复核结果：已解决。** `epub-reader-ui.el:111-149` 在图片
  source 标记完成后，把章首/章尾和每个正文行两侧的 TextUI 合成 cells 全部标成
  chrome。真实 reader buffer 独立扫描了 1,318 个 chrome 字符，产生 locator 的数量为
  0，且 first/last source 之外无漏标。`test/epub-reader-ui-test.el:109-150` 现在也扫描
  整个区域，不再只抽一个显式 chrome 字符。

### L-02 — P1 应修：图片、空块和内联 id 没有可靠坐标，fallback 也未实现

- **位置：** `epub-reader-render.el:271-298,308-340,370-384`；
  `epub-reader-locator.el:20-23,68-120`；`epub-reader-ui.el:124-141`；蓝图
  `docs/architecture.md:215-239`。
- **问题：** `emit` 跳过空 text，因此空段、pagebreak、空 anchor 消失；block key 只带被 emit
  节点自身 id，`span/a/section/aside` 等内联或容器 id 消失，fragment 查找只匹配 key suffix。
  图片的 alt caption 有 source，但实际 native image slice 没有，点在图上只能碰运气吸附邻块。
  locator 的 `context` 来自宽度相关的显示 buffer，却在 resolve 时完全不用；block key 又由
  `b%05d` 顺序计数，前方插块就失稳。所谓 fallback 实际只有 exact/同 block 最近 offset/本文档
  第一个字符，没有 quote/prefix/suffix、resolution quality、book/schema，无法覆盖这些洞。
- **修复建议：** DOM normalizer 为所有可链接 id 和空 pagebreak 生成零宽语义 anchor；图片 slice
  建立到 figure block 的显式映射；block key 优先 stable id/DOM path；实现蓝图规定的 exact →
  quote-near-block → quote-in-spine → spine-start 并返回 degraded 状态。测试必须在实际渲染后的
  image slice、空元素、inline id、合成空白上取点，不是只检查 alt string 属性。

- **复核结果：部分解决。** renderer 已为空/容器/inline/pagebreak id
  生成 U+2060 语义 anchor，block key 优先 `id:` 否则用 DOM `path:`，图片行在
  `epub-reader-locator.el:281-309` 获得显式 source。`locator.el:178-266` 也增加
  quote fallback/schema/quality；`render-test.el:133-170,230-254` 和 `ui-test.el:73-90`
  覆盖空/inline id、degraded quality 与实际图片 slice。然而：

  1. `locator.el:242-244` 只要同 block 的旧 offset 仍在范围内就报 `exact`，不核对
     prefix/suffix。在同 `id:stable` 块前插 `"XX "` 后，旧 locator 仍返回
     `quality=exact, position=8`，实际落在错字符 `a`。新测试通过改 block key 绕开了
     最危险的同-key 内容漂移路径。
  2. `render.el:391-392,419-420` 对同一段/figure 的每张图都使用同一
     `path/.../image` key。两图探针得到两个完全相同的
     `path:body/0:p/image`，第二张图的 locator 可静默恢复到第一张。
  3. locator 仍没有 book key，`spine-index` 也未参与 resolve 身份校验。

  应先校验 exact 位置的 quote，不一致则进入 quote fallback；为重复图片加 DOM
  sibling index，并补同-key 前插/删除、同段多图、跨书/跨 spine 负例。

- **最终复核结果：部分解决。** `epub-reader-locator.el:254-326` 现会在
  exact 前核对 prefix/suffix；前插 `XX ` 的独立探针以 `quote-near-block` 落到新
  source offset 10。`epub-reader-render.el:450-487` 为每个后代图片加 sibling index，
  真实章节的 3 张图得到 3 个唯一 key；schema/book/spine 字段和负例也已增加。
  但生产身份来源还是错的：`epub-reader-publication.el:725-731` 直接令
  `book-key=identifier`，违反 `docs/architecture.md:243-245` 的“identifier + 规范路径 +
  size/mtime + content hash，不能只信 publisher identifier”。探针证明两本共用同一
  identifier/path/block/text 的书仍得到 `quality=exact`。`render-test.el:313-331` 手工注入
  `book-a/book-b`，没有经过这条生产路径；同时持久模型应以 spine href 找章，不能
  只依赖易因重排漂移的数值 index。因此 exact/多图子项已关闭，book/spine identity
  子项仍阻断 gate。

- **收尾复核结果：已解决。** `epub-reader-publication.el:56-77,810-816` 以
  identifier、`file-truename`、size、mtime 和 EPUB 字节的 SHA-256 生成并缓存生产
  `book-key`；`epub-reader-locator.el:269-304` 以 `book-key + spine href` 判定持久身份。
  独立探针打开两个共用 identifier 的真实 EPUB，确认 identifier 相等而 book-key 不同。
  `test/epub-reader-publication-test.el:58-78` 验证生产 key 的跨书区分和同书重开稳定性，
  `test/epub-reader-render-test.el:353-375` 验证 publication→render→locator→resolve
  生产链会拒绝跨书恢复。

### R-01 — P1 应修：无条件把 source newline 变 ASCII 空格会破坏 CJK

- **位置：** `epub-reader-render.el:200-207,304-327`；蓝图
  `docs/architecture.md:172-199`。
- **问题：** `[ \t\r\n]+ -> " "` 对中英一刀切。实测 `中\n文 -> 中 文`、
  `中文\n，继续 -> 中文 ，继续`、`甲\n（乙） -> 甲 （乙）`，给中文全角标点前制造可见空格。
  TextUI 的 kinsoku 只能决定 wrap break，修不了 renderer 已经插入正文的 ASCII space。
  CSS Text 明确指出中文 source segment break 的“unbreak”通常需要无间隔拼接，而英文通常需要空格。
- **修复建议：** 把 whitespace normalization 做成按上下文、`xml:lang/lang` 和字符类别判断的
  独立模块；至少删除 CJK/CJK、CJK/全角标点、全角标点/CJK 周围的 source segment break，
  保留真实 U+0020；混排策略用 fixture 锁定。不要把此职责推给 TextUI。

- **复核结果：部分解决。** `epub-reader-render.el:236-283` 现会区分
  source segment break 与真实 U+0020；指定探针得到 `中文` 和 `中文，继续`，
  `render-test.el:173-191` 也从 XHTML 端到端覆盖中文、全角标点、显式空格和
  Latin。但 `--cjk-context-p` 在 `:204-211` 把 Hangul 和 category `h` 无条件当成
  无间隔书写，且没有传递 `xml:lang/lang`。探针 `한국어\n문장` 被错误合并为
  `한국어문장`；韩文通常以空格分词，应保留 segment break 生成的分词空格。
  因此原 finding 要求的“按 lang 和字符上下文”尚未完成；需增加 `zh/ja/ko`
  策略与韩文回归。

- **最终复核结果：已解决。** `epub-reader-render.el:138-157,177-230`
  现按 DOM 继承 `xml:lang/lang`，`:236-330` 仅在 `zh/ja` 且两侧为 CJK 上下文时
  删除 segment break，韩文与其他语言生成空格。独立探针验证 `zh/zh-Hant/ja`
  的 `中\n文` 和全角标点无多余空格，`ko/en/nil` 保留分词空格，inline
  `lang=ko` 也能覆写外层 `zh`。`test/epub-reader-render-test.el:196-232` 从 XHTML
  端到端覆盖 `zh/ja/ko`。

### R-02 — P1 应修：`<br>` 先生成换行，随后被归一化成普通空格

- **位置：** `epub-reader-render.el:161-207`。
- **问题：** inline mapper 的 `("br" "\n")` 表面正确，但 `--normalize-inline` 随后把换行折成
  空格。诗歌、地址、标题内显式换行等都会被读错；这不是 CSS source indentation，而是 DOM
  语义换行。
- **修复建议：** 为 `<br>` 使用不会参与 collapsible whitespace 的 sentinel/semantic run，
  normalize 后恢复 hard newline；locator 对 hard break 定义前后吸附规则。补连续 br、br 与
  CJK/inline face/link 相邻的测试。

- **复核结果：已解决。** `<br>` 在 `epub-reader-render.el:183` 带
  `epub-reader-hard-break` 属性，normalizer 在 `:249-251` 优先保留该换行。
  `render-test.el:193-228` 覆盖连续两个 br、CJK/加粗相邻、每个换行的 source
  坐标以及实际 TextUI 渲染后的三行布局。原探针不再把 `<br>` 折成空格。

### R-03 — P2 建议：还有三类静默语义降级

- **位置：** `epub-reader-render.el:161-198,299-348,367-384`；蓝图
  `docs/architecture.md:112-127`。
- **问题：** paragraph 内 inline image 被先从文本删除，再统一发到段后，改变阅读顺序；`ol`
  仍显示 bullet，没有序号；未知容器只递归 element children，直接 text node 会静默消失。
  图片 resolve 的所有 error 也被吞成 alt，没有诊断。
- **修复建议：** block/inline IR 保留 run 顺序，或明确在原位拆块；区分 ul/ol marker；unknown
  container 遍历 text 与 element；unsupported/error 采用可见但不崩溃的诊断节点。

### X-01 — P1 应修：未调用 TextUI 私有 API，但仍穿透了项目模块 seam

- **位置：** `epub-reader-render.el:22-23,80-85,253-255`；蓝图
  `docs/architecture.md:55-56,262-280`。
- **问题：** 对生产 `.el` 执行 `rg 'textui--'` 为零；当前只用 `textui-open/update/refresh/
  register-cleanup` 和 `textui-state`，这一项通过。但 renderer 直接调用 publication 私有函数
  `epub-reader-publication--parse-file`，并拿 `epub-reader-resource-file` 裸临时路径；反过来 renderer
  的 link keymap 又绑定 UI command，形成 renderer ↔ UI 的概念环。蓝图要求 section loader/
  resource resolver 由 publication 吃掉 EPUB 与临时路径知识，接口才是 test seam。
- **修复建议：** publication 暴露窄而深的 `load-section/resolve-resource` 公共接口，renderer 只收
  DOM/section 与 resolver；link map/动作留在 UI，renderer 仅附 href property。加依赖方向 lint，
  禁止跨文件调用其他模块的 `--` symbol。

- **复核结果：已解决。** 全部生产 `.el` 静态搜索仍无
  `textui--*`/`textui-kp-core--*`；`epub-reader-publication.el:714-773` 已暴露
  `load-section/resolve-resource`，renderer 只通过两个公开 seam 获取 DOM/资源。
  link keymap/动作在 `epub-reader-ui.el:92-108`。
  `test/epub-reader-contract-test.el:84-113` 静态拒绝 TextUI 私有 symbol 和跨文件
  `epub-reader-...--...` 调用；复审 grep 也只命中测试自身的 regex。

### X-02 — P2 建议：领域对象和整章 blocks 被放进 `textui-state`

- **位置：** `epub-reader-ui.el:82-101,165-180,256-275`；蓝图
  `docs/architecture.md:249-260`。
- **问题：** state 含 `:publication` 与 `:blocks`，与“state 只存 UI 状态；Publication/DOM/cache
  放 buffer-local session”直接不符。当前 plist copy 是浅复制，短期不会复制整个 DOM，但它让
  frame producer、命令、生命周期和未来 store 都依赖一个混合状态，阶段二 chunk/cache 更难收口。
- **修复建议：** 新建 buffer-local session，持有 publication/cache/store；TextUI state 只保留
  spine index、chunk range、loading/error、pending locator 等可比较 UI 值。

### T-01 — P1 应修：16 个测试与 fixture 不能支撑当前安全/正确性结论

- **位置：** `test/epub-reader-container-test.el:11-66`、
  `test/epub-reader-publication-test.el:21-78`、
  `test/epub-reader-render-test.el:43-114`、
  `test/epub-reader-contract-test.el:35-82`、
  `test/epub-reader-ui-test.el:27-68`、`test/fixtures-src/`。
- **问题：** 3 个 ZIP fixture 合计只有 4,235 bytes；恶意 fixture 只有一个 `../escape.txt`。
  file-count 测试只是把正常书上限设成 1；没有 entry/total size、ratio、目录洪泛、glob、碰撞、
  adapter 失败/超时、cleanup failure。publication 只有 flat NCX/nav 和 ASCII href。locator 唯一
  round-trip 是普通段落 offset 5 的同一 DOM、宽度 14→24；image 测试只看 alt anchor string，
  没在图片 slice 取 locator。CJK contract 只测 TextUI 对一条已清洗字符串的行首/行尾禁则，
  完全绕过 renderer 的 source whitespace normalization。
- **修复建议：** 先把本报告每个 P0/P1 做成最小回归 fixture。安全测试对两个 adapter 参数化；
  locator 做 point-space 表驱动；publication 引入 EPUBCheck 风格的 bad/good cases；CJK 从 XHTML
  source 经完整 render→TextUI。测试应断言失败阶段、错误类型、partial root 清理和 bounded output，
  不只断言 `should-error`。

- **复核结果：部分解决。** 测试已从 16 增至 36，新增 9 个 ZIP
  fixture；glob、case/NFC collision、目录数、central bytes、ratio/声明大小、伪元数据的
  实际流式上限、percent/namespace/required/remote/nav、合成距离、空/inline anchor、
  CJK/硬换行、degraded locator、实际 image slice 和模块契约都有回归。
  `./test/run-tests.sh` 的 36/36 确实通过。但测试套仍没有发现本次已复现的
  A-04 PUA/noncharacter/full-fold、P-01 root-relative OCF URL、P-02 空 required/
  version/remote fragment、L-01 TextUI 合成 chrome 间隙、L-02 同-key 前插与同段多图、
  R-01 韩文分词。container 也缺 timeout、坏 mimetype local header、cleanup failure、坏 local
  entry header 的回归；实际上限测试断言错误与 partial file，但“未先完整
  materialize”主要仍由 `:buffer nil` 的代码检查证明。所以它们能防止旧问题回归，
  不能支撑“14 条全部关闭”的声明。

- **最终复核结果：部分解决。** 测试现为 42/42；新增 OCF
  禁止区间/full fold、root-relative URL、空 required、坏 version、remote fragment/基本规范化、
  exact quote、cross-book/spine、多图 key、全 chrome 区域与 `zh/ja/ko` 端到端回归。
  然而 suite 仍未覆盖本次已复现的 remote dot-segment 等价 URL，也未从两个
  共用 publisher identifier 的真实 publication 验证生产 book fingerprint。因 P-02/L-02
  仍有漏洞，T-01 也不能标为完全解决。

- **收尾复核结果：已解决。** 测试现为 45/45。新增 remote literal/encoded
  dot-segment 重复 manifest、共用 publisher identifier 的双书 fixture，以及生产链跨书
  locator 负例，直接覆盖 P-02 与 L-02 最后两个缺口。

## 修复期间引入或暴露的新问题

- **P1：同段多图 key 冲突。** stable DOM-path 修复把每张后代图片都写成同一
  `/image` 路径（`epub-reader-render.el:391-392,419-420`）；这是修复 L-02 时引入的
  新身份冲突。**最终复核：已解决**，现以 sibling index 保证 key 唯一。
- **P2：`epub-reader-locator-goto` 返回类型不兼容。** 修复前 docstring/实现返回
  integer position；现在 `epub-reader-locator.el:273-279` 返回 resolution struct。如果这已是
  公开 API，应保持旧返回值并另加 `resolve`，或明确做一次版本化 breaking change。
- **P2：蓝图 X-02 仍未收口。** `epub-reader-ui.el:111-130,198-214,290-313`
  仍把 publication/section/blocks 放进 `textui-state`，与 `architecture.md:249-260` 的
  session/state 边界相反。它是初审已记录的 P2，不计入 14 条 gate finding，但会
  让第二阶段 chunk/cache 状态更难分离。
- **P2：第二轮新增 positional data clump。** `epub-reader-locator.el:141-190`
  以 6 元匿名 list 表示 source block，`epub-reader-render.el:543-548` 与
  `epub-reader-locator.el:348-370` 以 4 元 list 跨模块传 image anchor。这没有引入已复现的
  功能回归，但应改为 struct/命名 accessor，避免后续字段错位。

Standards 复核未发现第二轮新增的 `architecture.md` 硬违反或 TextUI 私有 API
调用；除上述 P2 可维护性问题外，未见新的独立 P0/P1 回归。

## 当前测试覆盖矩阵

| 模块 | 现有 45 测试实际覆盖 | 关键缺口 |
|---|---|---|
| Container（12） | open/close、两 adapter、traversal/cleanup、file/directory/entry/central/size/ratio 上限、glob、case/NFC/full-fold collision、OCF 禁止区间、假元数据实际流式 cap | timeout、mimetype/local-header 坏元数据、cleanup failure、实际 total cap |
| Publication（11） | EPUB2/NCX、EPUB3/nav、local/external href、percent/UTF-8/base/root-relative、namespace/required/unique id/version、local/remote URL 重复、remote fragment/dot-segment、生产 book fingerprint、nested span nav、公开 section seam | NCX 异常深度 |
| Render/locator（12） | 常见 block、image leaf/多图 key、TextUI reflow、最近合成距离、空/inline/pagebreak anchor、`zh/ja/ko` whitespace、hard br、exact quote/degraded quality、生产 book-key/spine-href 身份与 legacy schema 拒绝 | 重复 quote 歧义；inline image 顺序 |
| UI（6） | 居中/open cleanup、n/p、跨章 fragment、实际 image slice locator、整个 chrome 区域、空/容器/inline fragment | 坏/受限外链、resize/chunk 恢复、错误恢复 |
| Contract（4） | fixture 为真 ZIP、TextUI CJK kinsoku/source property、TextUI 与跨模块私有 symbol lint | 没有对 architecture 的 `textui-state` 内容做 contract lint |

## 已验证通过的点

- 普通 `../`、absolute path、drive prefix、反斜线、NUL/CR/LF 会被拒绝；`make-process`
  使用命令 argv 不经过 shell，
  没有 shell command injection。
- 不批量让 archive tool 选择目标路径，而是将 stdout 写入专属 temp root；ZIP symlink 不会直接
  materialize 为宿主 symlink。
- 打开中途的普通 Elisp error 会经 `unwind-protect` 删除 root；正常 kill reader buffer 会执行
  TextUI cleanup；现有对应测试通过。
- mimetype **内容**按字节精确检查；percent-encoded `..` 解码后能被 root escape 检查拒绝。
- 生产代码没有 `textui--*` / `textui-kp-core--*` 调用；TextUI 私有 API 合规项通过。
- `linear="no"` 被正确记录。阅读器经过它是允许的产品策略，不是 EPUB 3.3 违规。

## 是否可进入第二阶段

**是，gate 已解除，可以进入第二阶段。** 原 14 条 P0/P1 已全部解决，无部分解决或
未解决项。P-02 的三种等价 URL 探针得到同一 `resource-key`；L-02 的两个真实 EPUB
共用 identifier 但得到不同生产 fingerprint，并由跨书 locator 负例锁定。完整 ERT
为 45/45 通过、0 unexpected。

X-02、R-03、A-05、P-05 仍是 P2；可不阻断本 gate，但 X-02 应在第二阶段
chunk/cache 开发开始前先收口。
