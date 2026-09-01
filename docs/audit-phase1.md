# 第一阶段代码对抗性审计

审计日期：2026-08-31

审计对象：`epub-reader-container.el`、`epub-reader-publication.el`、
`epub-reader-render.el`、`epub-reader-locator.el`、`epub-reader-ui.el`、
`test/`、`test/fixtures*`，并以 `docs/architecture.md` 为蓝图。

## 结论先行

**目前不可进入第二阶段。** 16/16 ERT 只证明三个极小 fixture 的 happy path；
它没有证明 ZIP 资源上限是安全边界。现实现至少有一个可在任何大小检查触发前耗尽
Emacs 内存的 P0，另有 href、TOC、locator 和 CJK 的基础不变量尚未成立。

| 严重级别 | 数量 | 含义 |
|---|---:|---|
| P0 阻断 | 1 | 在处理不可信 EPUB 时可造成检查前资源耗尽 |
| P1 应修 | 13 | 会打开失败、读错内容、跳错位置或破坏阶段二依赖的不变量 |
| P2 建议 | 4 | 架构债、清理韧性或较小的语义降级 |

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

执行 `./test/run-tests.sh`：16/16 通过，0 unexpected。另做了四组定向探针：

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

### A-02 — P1 应修：清单本身无界，目录数和压缩比限制可绕过

- **位置：** `epub-reader-container.el:87-97,120-136`；蓝图
  `docs/architecture.md:66-68`。
- **问题：** `-Z1/-tf` 的完整输出先进入字符串再 `split-string`；文件数检查之后才发生。
  `file-count` 只统计非目录条目，任意多的目录项可绕过 10,000 限制并触发大量
  `make-directory`。代码完全没有压缩比、清单 byte 数、总条目数、路径 byte 长度或
  子进程时间限制；也只检查 mimetype 内容，未检查 OCF 要求的首条、stored、无 extra field。
- **修复建议：** 给中央目录解析设置输出 byte/条目/目录/时间上限，目录也计入总 entry 数；
  校验声明 size 与 ratio 并以 A-01 的实际流量上限兜底；同时验证 OCF `mimetype` ZIP 元数据。

### A-03 — P1 应修：成员名被当成 glob，列表条目与读取字节失去一一对应

- **位置：** `epub-reader-container.el:103-117,138-146`。
- **问题：** validator 接受 `*`、`?`、`[` 等字符，随后把成员名直接作为 archive tool 的
  pattern 参数。定向 ZIP 中请求 1-byte 的 `a*`，两个 adapter 均拼接返回 `a*` 与 `abc`
  共 3 bytes。攻击者可令一个已验证名称选择多个成员，破坏逐条大小、内容身份和总量核算。
  OCF 本来禁止 `*`、`?` 等字符，但当前没有实现这层拒绝。
- **修复建议：** MVP 最简单可靠的策略是完整拒绝 OCF 禁止字符，并为每个 adapter 使用
  literal member 选择能力；如果工具没有可靠 literal 模式，不要用 member pattern API，
  应改用已验证的中央目录/流式 extractor。两个 adapter 都补 `* ? [ ]` 恶意 fixture。

### A-04 — P1 应修：raw-string 去重挡不住规范化/大小写路径碰撞

- **位置：** `epub-reader-container.el:103-136,148-178`。
- **问题：** `seen` 只按 `equal` 比较 ZIP 原始名字。`A.xhtml/a.xhtml`、NFC/NFD 等在
  case-insensitive 或 normalization-insensitive 文件系统可落到同一 target，后条目静默覆盖
  前条目；代码还接受 OCF 禁止的引号、冒号、尾点、C0/C1 等名字。EPUB 规范明确要求同目录
  名称在 canonical normalization + full case folding 后唯一，不能把宿主文件系统的行为当保护。
- **修复建议：** 分目录建立规范化 case-fold key 并拒绝碰撞；实现 OCF 文件名/路径 byte
  长度与字符约束；写入前后都验证目标仍属于专属 root，并测试大小写、NFC/NFD 和尾点碰撞。

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

### P-03 — P1 应修：合法的远程 manifest resource 会使整本 EPUB 打不开

- **位置：** `epub-reader-publication.el:220-247`。
- **问题：** 每个 manifest href 无条件进入本地 `--normalize-path`；`https:` 会命中 drive/scheme
  检查并 signal。EPUB 3.3 允许 manifest 列出远程 publication resource，例如章节嵌入的远程
  audio。即使该资源不在 spine、也不需要当前 reader 获取，整本书仍会在 open 阶段失败。
- **修复建议：** resource model 区分 container URL 与 remote URL；解析并记录远程资源但默认
  不联网，只有实际渲染需要时才走明确的 capability/fallback/错误路径。测试“远程非 spine
  资源不妨碍本地正文”和 unsupported spine resource 的 fallback/诊断。

### P-04 — P1 应修：EPUB 3 `span + ol` TOC 分组被整棵丢弃

- **位置：** `epub-reader-publication.el:328-348`。
- **问题：** `label-node` 可以是 `span`，但创建 entry 又要求 `target` 非 nil；span 没有 href，
  所以合法的分组节点和所有 nested `li` 一起返回 nil。当前 fixture 只有两条 flat `a`，没有触发。
- **修复建议：** TOC entry 允许 target=nil 的 group，保留 children；或者显式 flatten children，
  但不能丢树。补 `span -> ol -> a`、多层 `a -> ol`、alt/title label 和 percent fragment fixture。

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

### R-02 — P1 应修：`<br>` 先生成换行，随后被归一化成普通空格

- **位置：** `epub-reader-render.el:161-207`。
- **问题：** inline mapper 的 `("br" "\n")` 表面正确，但 `--normalize-inline` 随后把换行折成
  空格。诗歌、地址、标题内显式换行等都会被读错；这不是 CSS source indentation，而是 DOM
  语义换行。
- **修复建议：** 为 `<br>` 使用不会参与 collapsible whitespace 的 sentinel/semantic run，
  normalize 后恢复 hard newline；locator 对 hard break 定义前后吸附规则。补连续 br、br 与
  CJK/inline face/link 相邻的测试。

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

## 当前测试覆盖矩阵

| 模块 | 现有 16 测试实际覆盖 | 关键缺口 |
|---|---|---|
| Container（4） | 正常 open/close；两个 adapter happy path；一个 `../`；正常书触发 file-count | bomb、流式 cap、ratio、目录/清单洪泛、glob、碰撞、坏 ZIP、timeout、cleanup failure |
| Publication（3） | 最小 EPUB2/NCX；最小 EPUB3/flat nav；一个本地/https/明文越 root href | namespace、required 字段、unique id、解析后 URL 唯一、encoded delimiter、坏 UTF-8、remote、nested span nav、NCX 深层 |
| Render/locator（3） | 常见 heading/p/quote/link；一张图有 alt anchor；正常正文跨宽度 exact round-trip | CJK source newline、br、inline image、空/id anchor、图片 slice、合成区域、degraded locator、DOM 变化 |
| UI（3） | 居中/open cleanup；n/p；一个跨章 heading id | 同章/inline/空 fragment、坏链接、外链 policy、resize 后 viewport、错误恢复 |
| TextUI contract（3） | fixture 是 ZIP；已清洗 CJK kinsoku；property 保留/U+200B 无 source | 没经过本包 renderer；没有中英混排、全角标点 source break、NBSP、emoji/combining、图片 native leaf |

## 已验证通过的点

- 普通 `../`、absolute path、drive prefix、反斜线、NUL/CR/LF 会被拒绝；`process-file` 不经过 shell，
  没有 shell command injection。
- 不批量让 archive tool 选择目标路径，而是将 stdout 写入专属 temp root；ZIP symlink 不会直接
  materialize 为宿主 symlink。
- 打开中途的普通 Elisp error 会经 `unwind-protect` 删除 root；正常 kill reader buffer 会执行
  TextUI cleanup；现有对应测试通过。
- mimetype **内容**按字节精确检查；percent-encoded `..` 解码后能被 root escape 检查拒绝。
- 生产代码没有 `textui--*` / `textui-kp-core--*` 调用；TextUI 私有 API 合规项通过。
- `linear="no"` 被正确记录。阅读器经过它是允许的产品策略，不是 EPUB 3.3 违规。

## 是否可进入第二阶段

**否。** 阶段二的 block viewport/chunk shift 会把 locator 和模块 seam 的问题放大，而不会修复它们；
继续叠功能还会让 P0 container 边界进入更多真实书籍路径。进入条件至少是：

1. 修复 A-01，并为 A-01～A-04 建立两个 adapter 的恶意回归；
2. 修复 URL resolver、remote resource、namespace/required 字段和 span nav；
3. 为合成区域、图片、空/id anchor 定义可测试 locator 行为；
4. 修复 CJK source segment break 与 `<br>`；
5. 收回 renderer→publication 私有调用，再跑完整 ERT 与新增 adversarial suite。

X-02、R-03、A-05、P-05 可在上述 gate 后排入阶段二最前部，但不应拖到发布加固才处理。
