# 性能冲刺终审

日期：2026-09-01

审计范围：reader `1ecb87f..2c69389`，TextUI `1075b6d..10ca3ed`。样书为
`财新周刊-第22期2026.epub`（31,955,757 bytes，20 个 spine item）。结论先行：
性能改善真实，且声称的数量级可以独立复现。最终复核范围为 reader
`2c69389..0efda05`、TextUI `10ca3ed..93f7b22`。R-01、T-01、T-03 已解决；T-02 的
正文 named face 探针通过，而 remap named-face 边界随后由 TextUI `92da425` 修复并通过复核。
该提交遗漏的 dotted entry `(FACE . FACE-NAME)` 又由 TextUI `e3fac30` 修复；最终反例与全量测试
均通过，原 4 条 P1 已全部关闭，gate 解除。

| 级别 | 初审发现 | 最终未关闭 | Gate 影响 |
|---|---:|---:|---|
| P0 | 0 | 0 | 无 |
| P1 | 4 | 0 | 已解除 |
| P2 | 5（含复核新增 R-02） | 4 | 不单独阻断 |

## 1. 独立性能复测

### 1.1 方法

- Emacs 31.0.91、`emacs -Q`，reader store 关闭；换章样本前强制 GC，避免把历史 GC
  时点误算成某个实现的稳定成本。
- batch 不挑最好看的 5 章，而是遍历全书 19 次 spine transition；滚动选择最长章节
  （index 8，164 blocks）连续 40 次。
- GUI frame 为 100×50；换章测试 index 2--6，每次命令后 `(redisplay t)`。预取命中测试
  单独记录同步预取成本，不能把它当成零成本。
- 原 reader + 原 TextUI 在样书 `.x-icon` 上因旧图片解码路径报错，无法跑完整 GUI。为得到
  可比旧基线，旧 reader 搭配 `10ca3ed` 的图片 fallback；它仍使用原 balanced KP、整块首绘且
  没有预取，因此这个结果是偏保守而非夸大的旧布局基线。

### 1.2 结果

| 场景 | 旧实现 | 当前实现 | 结论 |
|---|---:|---:|---|
| batch 换章，19 次，最慢/p95 | 1.003 s | 0.071 s | 约 14.1×；支持声称的 1.067→0.125 s 量级 |
| batch 换章，中位 | 0.565 s | 0.029 s | 改善稳定，不是单章偶然值 |
| batch 滚动，40 次，p95 | 0.056 s | 0.0059 s | 明显改善 |
| GUI 换章，5 次，最慢 | 3.313 s | 0.059 s（预取命中） | 支持声称的 3.362→0.050 s 量级 |
| GUI 换章，中位 | 2.987 s | 0.047 s（预取命中） | 命中时低于 150 ms 预算 |
| GUI 换章，当前冷路径中位/最慢 | — | 0.208/0.379 s | 与文档 0.398 s 冷路径相符 |
| GUI 滚动，40 次，中位/p95/最慢 | 0.061/1.689/1.772 s | 0.025/0.044/0.046 s | 当前 p95 低于 50 ms |

当前 GUI 五次预取本身耗时为 0.121--0.324 s（中位 0.149 s），命中后的换章耗时依次为
0.0588、0.0472、0.0500、0.0403、0.0396 s。也就是说，“预取命中 0.050 s”成立，
但它描述的是工作已提前完成后的交互延迟，不是整项工作的总 CPU/墙钟成本。

另以当前代码切回 `balanced` 复测：预取命中 GUI 换章中位 0.094 s、最慢 0.120 s，仍满足
换章预算；滚动中位 0.050 s、p95 0.142 s、最慢 0.155 s，未满足滚动预算。greedy 带来的
滚动收益是真实的，是否接受 ragged-right 则是必须明确记录的产品契约选择。

最终修复后再次遍历财新全部 19 次 spine transition：换章中位 **0.029826 s**、p95/最慢
**0.070425 s**。初审当前实现中位为 0.029046 s，差异约 2.7%，在单轮噪声范围内；四项正确性
修复没有令换章性能量级回退。

TextUI `92da425` 后又独立跑两轮相同的 19 次换章，median 分别为 **0.032417 s** 与
**0.031562 s**，p95/最慢分别为 0.073155/0.073155 s 与 0.073481/0.073481 s。相对上一轮
0.029826 s 略有约 6%--9% 波动，但仍稳定在约 30 ms、远低于 150 ms 预算，也未改变此前
1 秒级到数十毫秒的性能量级。

## 2. 正确性探针结论（初审）

| 检查项 | 结果 | 独立证据 |
|---|---|---|
| greedy CJK 禁则 | 通过所测常见边界 | 窄宽度下未让 `（《` 落在行尾，也未让 `），》。` 落在行首 |
| greedy text properties | 通过 | 逐字符 face/自定义属性及 source-offset 与输入一致 |
| greedy 两端对齐 | **不通过原契约** | balanced 非末行带 display glue；greedy 非末行没有，实际为 ragged-right |
| cache 宽度失效 | 通过 | 同输入命中 1 次规划；改宽度后规划计数 1→2 |
| cache text-scale 失效 | 通过 | 修改 `face-remapping-alist` 后规划计数 2→3 |
| 首绘后的 idle 扩展 | 通过 | range 0..2→0..64 后 locator offset 20→20，进度完全不变 |
| 交互冷 chunk shift | **失败** | 财新第 3 个 spine：range 0..2→1..2，locator offset 20→117，进度 2.22809%→2.30733% |
| 下一章预取安全预算 | 通过 | 把容器总量上限钉在已 materialize 的 1932 bytes 后预取被拒绝；累计量不增、chapter cache 不发布 |

预取调用链是 `epub-reader-ui--prefetch-chapter` → `--chapter-data` →
`epub-reader-publication-load-section` → container materialize 公共 API；没有另开解压后门，路径、
单成员/累计大小、压缩比、CRC 与快照绑定仍由容器层执行。

## 3. Findings

### R-01 — P1：交互 fast-path 的 chunk shift 会改变语义位置和进度

位置：`epub-reader-ui.el:1112-1136`、`epub-reader-ui.el:1140-1150`、
`epub-reader-ui.el:1160-1183`；违反 `docs/architecture.md:168`。

`interaction-fast-path` 明确跳过 reader 的 locator/viewport 捕获与恢复，只依赖 TextUI focus
anchor。真实样书的相邻块并不能保证这个锚点等价：上述探针把同一点从 paragraph offset 20
移到 117，并随即改变全书加权进度。用户一次普通滚动即可把错误位置写进 sidecar；这不是只影响
视觉行的误差。

修复建议：chunk source-order/range 变化一律以 reader locator 为真值，refresh 前捕获 locator 与
window-relative visual row，提交后 resolve 并恢复；若要保留 fast path，至少先证明被保留的
location-id/source offset 仍存在，否则自动回退语义恢复。增加直接调用 `--maybe-shift-chunk` 的
真实多段长文本回归测试，并断言 locator、进度和 window row。

**复核结果（2026-09-01）：已解决。** `epub-reader-ui.el:1112-1182` 已删除跳过 view-state 的
参数；任何实际改变 source-order 的 refresh 都捕获并恢复 reader locator 与各窗口视觉行，无新增
覆盖的 subset 收缩则不再执行。原财新反例保持 range `0..2`、offset `20→20`；独立扩大覆盖探针
使 range `0..32→15..47`，仍保持 block `id:p00030`、offset `20→20`、进度
`1.006078660%→1.006078660%`、视觉行 `4→4`。未发现新回归。

### T-01 — P1：将布局缓存设为 0 会令全部正文消失

位置：TextUI `textui.el:85-88`、`textui.el:627-660`。

Customize 文档承诺 0 表示禁用缓存；实现中 `(and (> size 0) (gethash ...))` 在 size=0 时得到
`nil`，随后却把任何不等于 `textui--cache-miss` 的值当成命中，最终返回 nil lines。独立探针
得到 `CACHE-DISABLED lines=nil`。这是合法配置触发的数据不可见问题。

修复建议：缓存关闭时必须直接执行 planner，或令 `cached` 显式为 miss sentinel；新增 size=0
的 balanced/greedy 渲染测试，断言行内容及 properties。

**复核结果（2026-09-01）：已解决。** `textui.el@93f7b22:685-722` 仅在 cache enabled 时查表；
size=0 显式走 miss/planner。连续两次独立调用得到 planner calls `2`、两次正文均为
`正文不可消失`、`probe-source=kept`，且 buffer-local cache 仍为 nil。balanced/greedy 回归均通过。

### T-02 — P1：布局缓存键不能感知 face/theme/font 语义变化

位置：TextUI `textui.el:614-621`、`textui.el:627-660`。

键包含字符串及其 property intervals、pixel width、strategy、face-remapping 和 frame cell
geometry，因此宽度与 text-scale 探针通过；但它只记录 symbolic face property，不记录解析后的
face attributes、font/fontset 或 theme generation。探针把同一 `perf-probe-face` 的 height 从
1.0 改为 2.0 后 planner 调用数仍为 1，缓存被原样复用。换主题、set-face 或换同 cell geometry
的字体时可能使用旧断点。

修复建议：在明确的 face/theme/font 变化入口清空 buffer-local cache，或把稳定的解析后 font/
face generation 纳入 key；不要仅依赖 `frame-char-width/height`。补充 set-face、theme 与 fontset
改变的失效测试。

**复核结果（2026-09-01）：部分解决，仍为 P1。** cache key 现在包含 pixel width、remap、正文
引用的 named face 解析值、frame font/geometry 与 display-environment generation；theme/font
hooks 递增 generation，直接绕过 hook 的 fontset 修改有公开 invalidation API。正文 face 探针的
planner 累计调用依次为 identical `1`、width `2`、scale `3`、face `4`、theme `5`、font `6`。
但 `textui.el@93f7b22:641-679` 只解析正文 properties 中的 named faces，没有解析
`face-remapping-alist` 所引用的 named face。独立反例设置 `((default perf-remap-face))`，第一次规划
后把 `perf-remap-face :height` 从 1.0 改为 2.0，planner calls 仍为 `1→1`，即 `stale=t`。
这正是原 finding 的 remap/face 组合边界，不能算彻底关闭。

**第二次复核（TextUI `92da425`）：部分解决，仍为 P1。** `textui.el:655-684` 现在递归收集
`face-remapping-alist` 的 named faces，与正文引用 faces 合并后写入解析 metric signature。原样
重放 `((default perf-remap-face))` 反例，修改 height `1.0→2.0` 后 planner calls 从 `1→2`，
`stale=nil`；新增 `textui-text-layout-cache-resolves-named-remap-faces` ERT 冻结了同一反例。
但 Emacs 自身的 `face-remapping-alist` docstring 明确允许 `(FACE . REPLACEMENT)`，且
REPLACEMENT 可直接为 face name。合法值 `((default . perf-remap-dotted-face))` 进入
`textui--face-symbols` 后，`cl-mapcan` 把 dotted tail 当 proper list，独立探针稳定得到
`(wrong-type-argument listp perf-remap-dotted-face)`，布局失败。119 项测试只覆盖
`((default textui-test-layout-cache-face))` 的 proper-list 写法，未覆盖该合法 grammar。

**第三次复核（TextUI `e3fac30`）：已解决。** 新增 `textui--face-remap-symbols`，按 remap alist
grammar 逐 entry 分别遍历 car 与 cdr，不再把 dotted tail 交给 `cl-mapcan`。原
`((default . perf-remap-dotted-face))` 探针现在正常布局；face height `1.0→2.0` 后 planner calls
`1→2`、`stale=nil`，再次使用同一上下文仍命中缓存。proper-list 写法也保持 `1→2`。
`textui-text-layout-cache-accepts-dotted-named-remap-faces` 冻结了准确反例，T-02 最终关闭。

### T-03 — P1：greedy 默认路径没有保持既有两端对齐契约

位置：reader `epub-reader-render.el:25-33`、`epub-reader-render.el:643-646`；TextUI
`textui.el:600-612`；契约见 `docs/architecture.md:129`。

CJK 行首/行尾禁则和 text-property 传递在探针中成立，但输出并不与 KP 的视觉契约等价：同一
段落的 balanced 非末行含伸缩 display glue，greedy 完全没有，因此默认正文变成
ragged-right。`docs/perf-notes.md:82-83` 已诚实记录这一点，但 architecture 仍写着正文接受
像素级两端对齐。性能优化不能同时声称“保持两端对齐契约”。

修复建议：二选一并形成可测试契约：（a）把 ragged-right 明确批准为 reader 默认视觉策略，
更新 architecture/ADR、用户选项与视觉基线；或（b）实现满足预算的快速 justified 路径。
若选择（a），本条可按有意识的产品决策关闭，而不是伪装成输出等价。

**复核结果（2026-09-01）：已解决。** 实现选择方案（b）：greedy 与 KP 仅使用不同断点算法，
随后共用 justification；TextUI ADR 0036、reader architecture/README 已统一这一契约。独立探针
过滤带 `textui--synthetic-spacing` 的显示胶水后，源字符串与逐字符 properties 均完全相同；
所测 CJK 行首/行尾禁则仍成立，五条非末行全部带 `textui--pixel-justified` 且实测宽度均为
8 pixels。合成胶水明确无 source offset，不构成源 property 丢失。

### P-01 — P2：idle 预取仍可能制造单线程输入卡顿

位置：`epub-reader-ui.el:302-331`、`epub-reader-ui.el:484-521`。

预取安全边界正确，但 Emacs idle callback 仍在主线程同步花 0.121--0.324 s。它改善了后续换章，
却没有抢占能力；用户恰在该窗口输入时仍可能感到一次 jank。

建议：分阶段调度 materialize/parse/render，阶段间重新 idle；记录 callback wall time，超过小预算
便 yield。至少把“命中延迟”和“预取成本”分别展示在长期基准中。

### D-01 — P2：性能证据没有可重复的仓内 harness 与原始样本

位置：`docs/perf-notes.md:46-57`、`docs/perf-notes.md:96-111`。

文档有方法与汇总值，但样书是私有文件，仓内没有可运行命令、机器信息、原始 sample 或公开替代
fixture；后续优化者无法区分性能回归、环境差异与统计口径变化。

建议：提交不含版权样书的 benchmark harness、JSON/TSV 输出格式和合成大章 fixture；私有样书
只作为可选输入，并同时报告 cold、prefetch cost、prefetch-hit 与 redisplay。

### A-01 — P2：新增公共 wrap 策略缺少架构决策闭环

位置：TextUI `README.md:278-293`、`docs/adr/0033-*.md:123-148`；reader
`docs/architecture.md:129`。

`:wrap greedy` 已进入 TextUI 公共 element API 并被 reader 默认依赖，但 reader 蓝图仍描述
KP-only 行为；TextUI 的相关 ADR 也未记录这次 capability、兼容性和非等价输出。这会让未来维护者
误把 ragged 行为修回或误认为 greedy 与 balanced 只是性能差异。

建议：补一个短 ADR，明确策略语义、默认权归属、CJK/property 保证、两端对齐差异和 cache
invalidation 契约；同步 architecture。

**复核结果（2026-09-01）：已解决。** TextUI ADR 0036 已明确 break strategy 与 alignment
正交、CJK/property 保证和 cache invalidation；reader architecture/README 已同步。Standards
复核另指出 ADR 0033 所要求的 `examples/` prototype 尚缺，该文档流程缺口单列在 Standards，
不重新打开本条“决策未记录”的原 finding。

### A-02 — P2：后台任务继续使用裸 list 传递多字段状态

位置：`epub-reader-ui.el:484-521`。

预取/扩展/图片 idle job 用 `car`/`cadr`/`nth` 解包多个同类型字段，generation、session、index
与 buffer 很容易在后续改动中错位，且审查时难以看出所有权边界。

建议：改成命名 plist 或 `cl-defstruct`，并在执行入口统一验证 buffer live、session identity 与
generation；这是可维护性建议，不是当前安全绕过。

### R-02 — P2：默认 cold guard 不再主动扩大 chunk

位置：`epub-reader-ui.el:52-69`、`epub-reader-ui.el:368-393`、
`epub-reader-ui.el:1175-1182`；期望见 `docs/architecture.md:163-164`。

默认 first-paint 为 2 blocks、scroll budget 为 1 block。point 到第二块 guard 时，scroll range
只能是当前 `0..2` 的子集 `1..2`，新加入的 subset guard 会跳过 refresh；财新探针实际得到
`0..2→0..2`。`epub-reader-scroll-forward` 到 buffer 末尾后仍会通过 `--goto-block-index` 拉取下一
块，所以书没有读不下去，locator 也不漂移；但 architecture 所称“接近 guard 时提前扩展/滑动”
在默认配置下失效，可能把延迟推到触底命令。

建议：把 scroll budget 定义为“新增块预算”，产生带重叠且向滚动方向增加覆盖的 range；新增默认
参数下的前后 guard 测试，断言 coverage 增加、locator/视觉行不变。该问题影响平滑度而非语义
正确性，故记 P2，不单独阻断本 gate。

## 4. 两仓库测试

| 仓库/环境 | 结果 |
|---|---|
| epub-reader `0efda05`，batch 全量 | 103 total：101 passed，2 GUI skipped，0 unexpected |
| epub-reader 当前 HEAD，GUI focused | 2/2 passed |
| TextUI `e3fac30` 加既有工作树修复 | 120/120 passed |

TextUI 的 120 项包含其既有未提交 focus/position 修复及 2 个测试；dotted remap 最终修复单独按
`92da425..e3fac30` 审查。本审计没有修改或清理 TextUI 工作树。reader 两项依赖 graphical
display 的测试在 batch 中按预期 skipped，随后在 GUI 中单独 2/2 通过。

## 5. Standards review

- **High / hard finding**：reader 的交互 chunk fast path 跳过语义 locator/viewport 恢复，直接
  违反 `architecture.md:168` 的模块责任与不变量。
- **Medium / hard finding**：TextUI cache key 没有覆盖 README 所称的完整 display context；
  symbolic face 相同但解析结果改变时会复用陈旧布局。
- **Medium / hard finding**：新的 public `:wrap` capability 缺少与 reader 架构、TextUI ADR
  对齐的决策记录。
- **Low / hard finding**：`architecture.md:129,162,176-181` 仍描述 KP-only、无跨宽度缓存的旧实现。
- **Low / judgment finding**：后台任务的裸 list 是 Primitive Obsession，字段边界不够自解释。
- 通过项：reader 生产代码仍只调用 TextUI 公共 API，没有 `textui--*` 私有调用。

初审 Summary: standards 轴有 1 条 high、2 条 medium、2 条 low；其中 locator 不变量的违例足以阻断。

### 最终 Standards 复核

- **Medium / hard**：TextUI `textui.el:641-679` 遗漏 remap 中的 named face，违反
  TextUI `README.md:291-298` 与 ADR 0036 的 display-context/cache 契约。
- **Medium / hard**：默认 first=2、scroll=1 时 guard 候选恒为 subset 而被跳过，与
  `architecture.md:163-164` 的主动扩展描述不一致；读取仍可由 buffer-end fallback 继续。
- **Low / hard**：ADR 0036 已补，但没有 ADR 0033 所要求的 `examples/` capability prototype。
- **Low / judgment，Mysterious Name / Primitive Obsession**：`small-budget` 用 nil/`first`/`scroll`
  同时表达总预算与新增预算，增加 range 语义错配风险。
- 通过项：reader/TextUI 公共 seam 未回退；R-01 的 locator/viewport 所有权与 T-03 的对齐契约
  已闭环。

Summary: Standards 轴 4 条未关闭，最严重为 remap named-face cache stale 与默认 guard 不扩展。

#### `92da425` 增量 Standards 复核

- **High / hard**：TextUI `textui.el:634-639,661` 的 `cl-mapcan` 假定所有 cons 都是 proper
  list；Emacs 明文允许 `(FACE . REPLACEMENT)` 且 replacement 可直接为 face symbol。合法 dotted
  remap 触发 `wrong-type-argument listp`，违反 TextUI README 与 ADR 0036 的 cache/layout 契约。
- **Low / judgment，Primitive Obsession**：无 grammar 的通用 cons 递归可能把 attribute/filter
  value 中碰巧也是 face 的符号误认成布局依赖，增加无谓签名计算与失效。
- 通过项：proper-list、plist、nested、filtered、nil 与 symbolic-cycle 形状，以及公共 API 边界。

Summary: `92da425` Standards 轴 2 条未关闭，最严重为合法 dotted remap 使布局直接失败。

#### `e3fac30` 增量 Standards 复核

合法 dotted remap 已由 entry-aware visitor 接受，原 high/hard 违反关闭；改动仍局限于 TextUI
私有 cache-context 计算，没有改变公共 API、布局算法或 reader 模块边界。dotted、proper、plist、
nested、filtered、nil 与 symbolic-cycle 探针均通过。

- **Low / judgment，Primitive Obsession**：嵌套 face-spec 仍使用通用 cons/symbol 递归，可能把
  `:weight bold` 中恰好也是 face 的属性值误算成额外依赖，造成无害但多余的签名计算/失效；后续
  可改成完整 grammar-aware visitor。

Summary: `e3fac30` Standards 轴无 hard finding；1 条 Low 判断项不阻断 gate。

## 6. Spec review

- **High**：交互 cold chunk shift 会把当前 locator/progress 移到另一语义位置。
- **High**：合法配置 `textui-text-layout-cache-size=0` 会使正文为空。
- **Medium**：face/theme/font 改变时布局 cache 可陈旧，宽度和 text-scale 的直接用例则正确失效。
- **Medium**：greedy 保持了所测 CJK 禁则和 text properties，但没有保持 KP 两端对齐输出契约。
- **Low**：性能文档缺少可提交、可复跑的 harness 与原始数据。
- 通过项：性能声称量级成立；idle 扩展保持 locator/progress；预取仍经过惰性容器安全检查与累计预算。

初审 Summary: spec 轴有 2 条 high、2 条 medium、1 条 low；性能目标达到，但当时正确性目标未全部达到。

### 最终 Spec 复核

规格子审查对明确列出的四个基本反例报告 PASS：R-01 的 subset/coverage-expanding 路径、T-01 的
无缓存直接规划、T-02 的正文 face/theme/font 状态、T-03 的 kinsoku/source-property/
justification 均通过，且没有有害 scope creep。独立扩展的 remap named-face 探针随后证明 T-02
只部分解决；该证据计入最终 gate，但不改写规格子审查本身的报告。

Summary: Spec 轴基本反例 0 条失败；扩展 T-02 契约边界后仍有 1 条未关闭。

#### `92da425` 增量 Spec 复核

目标反例 planner calls `1→2`，width 与 remap scale 的既有失效行为未回退；新增测试准确冻结
该 exact 边界。规格子审查没有发现遗漏、错误或有害 scope creep；随后 Standards 的合法 grammar
扩展探针发现 dotted entry 回归，因此 exact probe PASS 不足以关闭整个 T-02。

#### `e3fac30` 增量 Spec 复核

dotted `((default . FACE))` 与 proper-list `((default FACE))` 均能布局并在 metric 改变后从一次规划
增至两次；第三次相同上下文维持两次，证明没有把缓存退化成永不命中。新增回归准确覆盖解除条件，
没有遗漏、错误或有害 scope creep。**Spec PASS：T-02 关闭，P1 未关闭数为 0。**

## 7. Gate 结论

**Gate 解除，可以按正确性与性能完成本轮冲刺验收。** 原 4 条 P1 均已关闭；最终 dotted
named-face 探针正常布局，metric 改变后 planner calls `1→2`、`stale=nil`，TextUI 120/120
通过。此前财新换章两轮中位 0.032417/0.031562 s 的性能结论不变。R-02 与 P-01、D-01、A-02
继续作为 P2 维护项跟踪，不再阻断本 gate。
