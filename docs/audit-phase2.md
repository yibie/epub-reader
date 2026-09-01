# 第二阶段代码聚焦审计

审计日期：2026-08-31

审计基线：`34f7341...118b787`，覆盖四个第二阶段提交：

- `8d5ffdc`：session/state 分离与第一阶段 P2 收口；
- `7bcc2cd`：预算化 chapter viewport；
- `eb6f06b`：spine/history/TOC；
- `118b787`：版本化阅读进度 store。

规格基线为 `docs/architecture.md`，重点对照 viewport（145-170）、locator/store
（215-248）、state/TOC（250-261）和第一版验收（285-315）。执行
`./test/run-tests.sh`：**62/62 通过，0 unexpected**。

最终复核基线为 `118b787...30d5770`，对应 viewport、store、TOC、progress 和
限制说明五个修复提交。复核重新执行 `./test/run-tests.sh`：**70/70 通过，0 unexpected**，
并另跑五条 P1 的独立运行时探针。

末次复核基线为 `c524584...b885c71`，严格只检查 S-01/S-04。新增相关 ERT
**4/4 通过，0 unexpected**；未重跑或重新裁决其他模块。两个独立对抗探针分别覆盖
“两个 reader 都发生过位置变化但逆序保存”以及“stale 判定后、rename 前锁已被新活 owner
替换”的窗口。

最终复核基线为 `f456bd9...a780193`，仍只检查 S-01/S-04。实现者报告 76/76；本审计运行
两条新增定向 ERT **2/2 通过**，并原样复跑 dirty-old 与两方 ABA 探针，再补一条只针对
S-04 恢复分支的第三 contender 交错探针。

## 结论先行

**最终 Gate 仍未解除，不建议进入下一阶段。** S-01 已彻底解决：真实位置变化时立即 stage，
dirty-old 逆序保存恢复 spine 1。S-04 的原两方 ABA 与 inode 重用反例也已转绿，但实现会先把
可能属于新活 owner 的 canonical lock 搬到 quarantine，复核 identity 失败后再放回；这个短暂
空窗允许第三 contender 取得 canonical lock。确定性交错探针留下 canonical=`third-live`、
quarantine=`replacement-live`，事务互斥仍可能失效。因此 S-04 仍为**部分解决的 P1**。
本轮没有重新审计其他 finding。

| 最终状态 | 数量 | Finding |
|---|---:|---|
| P0 阻断 | 0 | 无 |
| 原 P1 已解决 | 5 | V-01、V-02、S-01、T-01、G-01 |
| 新发现 P1 部分解决 | 1 | S-04（ABA 恢复空窗） |
| P2 已解决 | 3 | S-02、X-01、X-02 |
| P2 部分解决 | 1 | V-03 |
| P2（沿用上轮结论） | 2 | V-04、S-03；本轮未复核 |

## 累计复核探针摘要

| 目标 | 最终实测 | 判定 |
|---|---|---|
| V-01 视觉行恢复 | 两个 window 的 locator block/offset 均相同；长段 shift 前后 visual row `6 -> 6` | 已解决 |
| V-02 locator 属性预算 | chunk `(0 21)` 外无 `epub-reader-source`；canonical blocks 的 source-property 数为 0；当前 rendered slice 有属性 | 已解决 |
| S-01 文件事务 | 人为交错时锁覆盖 read/merge/write，竞争方 pending 保留；两个 book-key 均存活，无残留锁 | 低层事务已解决 |
| S-01 未移动旧 reader | B 前进到第 2 章并关闭，未移动的旧 A 后关闭；重开 spine 1 | 已解决 |
| S-01 已移动旧 reader | A 先移动但不保存；B 后到第 2 章并先保存；A 后关闭；capture timestamp 顺序正确，重开 spine 1 | 已解决 |
| T-01 TOC 重开 | 选中 `0/0/0` 后隐藏/重开，buffer point 与 window point 的 key 都是 `0/0/0` | 已解决 |
| G-01 书末百分比 | 书首 `0.0`，同一长块内 `0.0 -> 9.091098`，书末 `100.0` | 已解决 |
| V-04 单巨块 | 字符预算 2,000，50,000 字符块仍形成 `(0 1)` | 限制属实，接受 |
| S-03 timer（上轮） | `b885c71` 前 repeat 参数为 `t`；本轮未独立复核其新实现 | 本轮不裁决 |
| S-04 普通孤儿锁 | 同主机 dead PID owner 可接管，locator 持久化，lock 无残留 | 已解决 |
| S-04 两方 ABA | stale check 后把旧锁替换为有效 live-owner 锁；outer 返回 nil，新 lock 与 nonce 保留 | 已解决 |
| S-04 inode 重用 | 相同 file-identifier 但 owner nonce 或 ownerless mtime 不同 | 均判为不同 instance |
| S-04 恢复空窗 | outer 搬走 replacement lock 后，第三 contender 先建 canonical；restore 失败并遗留 replacement quarantine | **未解决，仍阻断** |

## 初审独立探针摘要（修复前）

| 探针 | 实际结果 |
|---|---|
| 长段视觉折行后 shift | locator 的 block/offset 均相同，但 point 的可视行由 6 变为 11；代码捕获的逻辑 row 为 0 |
| 10k 段预算 | 当前 chunk 为 32 blocks；chunk 外第 132 块已经带逐字符 source 属性，全章共 280,007 个带属性字符 |
| 单巨块 | 字符预算 2,000 时，50,000 字符块仍得到 chunk `(0 1)` |
| guard 边界 | `[100,132)`、guard=8：前缘内侧 107 shift，前缘恰好 108 不 shift，后缘恰好 124 shift |
| 同书双 handle | 新位置 offset 14 先 flush，旧 handle 后 flush，最终持久值退回 offset 1 |
| read/merge/write 交错 | 在第一个 handle 读后、rename 前插入第二个 book-key 的 flush，第二条记录最终丢失 |
| schema 0 | sidecar 保留且返回 warning，但没有迁移，locator 为 nil，后续 flush 被禁用 |
| 首尾边界 | 第一章 previous/history-back/scroll-back 与末章 next/scroll-next 均正确报错且不改 state/history |
| 加权百分比 | 最后一章最后 source 字符为 95.734337%；同一首块首尾均为 0% |
| TOC | 多级折叠、展开和当前章刷新通过；选中 `0/0/0` 后 `q`，重开时 row key 为 nil |
| state/session | reader `textui-state` 仅含 spine/chunk/loading/error/pending/quality；session 为独立 buffer-local struct |

## Findings

### V-01 — P1 应修：viewport row 用逻辑行计算，视觉折行后窗口跳动

- **位置：** `epub-reader-ui.el:611-647`；蓝图 `docs/architecture.md:164-168`。
- **问题：** capture 用两次 `line-number-at-pos` 相减，restore 用 `forward-line` 和
  `line-beginning-position`。它们只认识 buffer 中的逻辑换行，不认识窄窗口里同一长段产生的
  visual rows。长段中 point 与 window-start 位于同一逻辑行时，捕获 row=0；refresh 后
  window-start 被拉回段首。
- **证据：** 2,000 字符单段、point 在 source offset 800 的探针中，shift 前后 locator
  block/offset 都相同，但可视 row 从 6 变为 11。现有
  `test/epub-reader-ui-test.el:278-314` 只使用不会视觉折行的短段，因而误把 logical row
  当成 viewport row。
- **修复建议：** 为每个 window 捕获 top locator 与 point locator，优先直接恢复 top
  locator；或者在对应 window 上用 `count-screen-lines`/`vertical-motion` 捕获并恢复真实
  screen row。新增窄窗长段和同 buffer 多 window 回归。
- **最终复核结果：已解决。** `epub-reader-ui.el:660-707` 逐 window 保存 point locator、
  top locator 和 `count-screen-lines` 视觉行，恢复时优先 top locator、缺失时才用
  `vertical-motion`。新增双 window 长段测试位于 `test/epub-reader-ui-test.el:317-374`；
  独立探针确认两窗语义 locator 不变，代表窗 visual row 为 `6 -> 6`。

### V-02 — P1 应修：chunk 预算只限制 TextUI leaf，不限制全章逐字符 locator 属性

- **位置：** `epub-reader-ui.el:200-217,446-459`；
  `epub-reader-render.el:402-449`；蓝图 `docs/architecture.md:147-162,217-223`。
- **问题：** `--load-chapter` 先对整章调用 `epub-reader-render-section`；其 `emit` 在 block
  进入 viewport 前就对每个字符执行 `epub-reader-locator-attach-source`。frame 确实只产生
  预算内 leaf，但最昂贵的逐字符 vector/book/spine text properties 已覆盖全章，内存仍随
  章节全文增长，违反“只在当前 chunk 生成逐字符 offset”。
- **证据：** 10k fixture 初始 chunk 只有 32 blocks，但 chunk 外第 132 块的首字符已经有
  `epub-reader-source`，所有 cached block 合计 280,007 个带属性字符。现有测试只断言
  `producer-block-count`/chunk range，没有检查 chunk 外 block 是否 materialized。
- **修复建议：** chapter cache 保存无 source-vector 的规范文本与 block metadata；只在
  `epub-reader-render-block-element` 的当前 slice 副本上附 source/book/spine 属性。locator
  quote 搜索读取规范文本，不应要求整章预先 materialize text properties。
- **最终复核结果：已解决。** canonical block text 不再附 locator property，只有
  `epub-reader-render-block-element` 生成当前 slice 时附加。`test/epub-reader-ui-test.el:233-294`
  已检查 chunk 外 block；独立探针进一步得到 canonical source-property blocks=0、chunk 外
  source=nil，而当前 rendered slice 仍可生成 locator。

### V-03 — P2 建议：前后 guard 边界不对称

- **位置：** `epub-reader-ui.el:680-708`。
- **问题：** 前缘用 `< distance guard`，后缘用 `<= distance guard`。在相同距离恰好等于
  guard 时，向前不 shift、向后会 shift，滚动方向不同会产生一块的迟滞差。
- **证据：** `[100,132)`、guard=8 时，block 107 触发、108 不触发，而 block 124 触发。
- **修复建议：** 明确 guard 是闭区间还是开区间并让两端对称；增加 start/end、guard=0、
  guard 大于半个 chunk 的表驱动测试。
- **最终复核结果：部分解决（仍为 P2，不阻 Gate）。** `epub-reader-ui.el:740-746` 已统一使用
  `<=`，也增加了等号/guard=0 测试；但 `end` 是 exclusive，`[100,132)`、guard=8 时左侧
  实际覆盖 100..108（9 blocks），右侧覆盖 124..131（8 blocks），guard=0 更只有左侧
  block 100 能命中。当前测试 `test/epub-reader-ui-test.el:307-315` 把这一非对称结果固定成了
  预期，因此“inclusive and symmetric”的命名仍不成立。建议以距首/末有效 block 的距离
  统一计算。

### V-04 — P2 建议：字符预算是软上限，单个巨块可任意超限

- **位置：** `epub-reader-ui.el:30-39,242-268`；蓝图 `docs/architecture.md:157-158`。
- **问题：** `or (= end start)` 保证首块无条件进入；这符合蓝图“单个超长段落至少独立纳入”，
  但意味着 `chunk-max-characters` 不是内存上限。探针以 2,000 上限得到一个 50,000 字符
  chunk；接近 container entry 上限的单段仍可能一次进入 TextUI layout。
- **修复建议：** 保留“至少一块”的产品语义，但另设 oversized-block hard cap/诊断，或把
  超长 paragraph 切成带稳定 sub-offset 的 render slices；至少补一个超预算单块回归，防止
  未来误把 soft budget 当安全边界。
- **最终复核结果：已知限制接受（P2）。** 独立探针确认 2,000 字符预算仍会完整纳入 50,000
  字符单块。这与蓝图 `architecture.md:158` 的“单个超长段落至少独立纳入”一致，响应文档也
  明确不把它宣传成安全内存上限。它不阻断当前 Gate，但公开发布前应有诊断或 hard-cap 方案。

### S-01 — P1 应修：原子 rename 没有使 read/merge/write 成为原子事务

- **位置：** `epub-reader-store.el:121-130,132-176`；蓝图
  `docs/architecture.md:241-247`。
- **问题：** 同目录 temp + mode 0600 + rename 的单次替换是原子的，失败 temp 也会清理；
  但 `read(:164) -> merge -> rename(:175)` 没有锁/CAS。两个 handle 可基于同一个旧 snapshot
  各自写回，后者覆盖前者。对相同 book-key，pending 只存 locator，`:updated` 到 flush 才生成；
  所以较旧 buffer 先 stage、较新 buffer 先 flush、旧 buffer 最后关闭时，会把进度倒退并获得
  更新的 timestamp。
- **证据：** 同书双 handle 把 offset 14 回退为 1；在首个 handle read 后插入另一个
  book-key 的 flush，第二条记录被首个 stale snapshot 删除。现有
  `test/epub-reader-store-test.el:19-49` 只顺序 flush `book-a`/`book-b`，没有并发窗口或同书冲突。
- **修复建议：** `stage` 同时记录 capture timestamp；flush 在 sidecar 级跨进程锁内完成
  read/validate/merge/write，并仅在 staged timestamp 新于现有记录时覆盖同 key。锁必须覆盖
  rename 前整个事务，异常用 `unwind-protect` 解锁；测试用两个同 key handle和确定性交错点。
- **最终复核结果：部分解决，仍为 P1。** `epub-reader-store.el:145-155,158-246` 已让 stage
  携带 capture time，并以目录锁覆盖 read/merge/write；独立确定性交错探针确认竞争方被阻止、
  pending 保留，随后重试后两个 book-key 都存在。可是 UI 每次保存都会重新调用 stage
  (`epub-reader-ui.el:391-398`)，kill cleanup 也先重新捕获当前位置再 close
  (`epub-reader-ui.el:1357-1363`)。真实双 reader 探针中，B 移到第 2 章并先关闭，未移动的旧 A
  稍后关闭后，重开从预期 spine 1 退回 spine 0。原因是 A 的 stale locator 在关闭时获得了
  更晚时间戳。`test/epub-reader-store-test.el:51-73` 人工让旧 locator 先 stage，因此没有覆盖
  生产反例。修复应以“最后一次真实位置变化”的时间/版本为准，并让未 dirty 的 buffer 在
  idle/kill 时只 flush 已有 pending，不重新 stage。
- **末次复核结果：仍是部分解决，P1 未关闭。** `b885c71` 引入 progress key、dirty state 和
  one-shot debounce；未移动的旧 reader 晚关闭探针现正确恢复 spine 1。但
  `epub-reader-ui.el:420-466` 在位置变化时只保存 key/dirty，真正调用
  `epub-reader-store-stage` 时才由 `epub-reader-store.el:153-163` 生成 `float-time`。
  对抗探针让 A 先移动但不触发 timer，B 后移动到第 2 章并先关闭，A 最后关闭；A 确认
  `dirty=t`，重开却从预期 spine 1 回到 spine 0。时间戳仍代表保存顺序而非位置变化顺序。
  `test/epub-reader-store-test.el:77-102` 只覆盖 A 从未移动。应在 observe 时捕获 locator 与
  timestamp（或等价单调 revision），后续 idle/kill 仅 flush 该 snapshot，并新增两个 reader
  都 dirty、逆序 flush 的回归。
- **最终复核结果：已解决。** `epub-reader-ui.el:420-470` 在 observe 到 locator 变化时立即
  `epub-reader-store-stage`，使 pending 的 `:updated` 在真实位置变化时冻结；idle/chapter/kill
  只 flush 已捕获 snapshot。原 dirty-old 探针得到 `timestamps-ordered=t`，B 的较新位置先落盘、
  A 后关闭后重开仍为 spine 1。对应回归 `test/epub-reader-store-test.el:104-136` 通过，S-01
  关闭。

### S-04 — P1 应修：目录锁在进程崩溃后永久阻塞 store

- **位置：** `epub-reader-store.el:158-194`。
- **问题：** 正常异常由 `unwind-protect` 删除 `.lock`，但 SIGKILL、宿主崩溃或断电无法运行
  cleanup。锁目录不含 owner PID/host/start-time，也没有 stale detection；此后所有 reader 都只会
  等到 timeout，且没有自动恢复路径。
- **证据：** 独立探针预先创建与一次崩溃等价的 `.lock`，flush 报
  `Timed out waiting for EPUB sidecar lock`；lock 仍存在，pending 虽保留但后续每次保存都会重复
  失败。这是 `746eac1` 引入锁后的新回归，现有测试只覆盖正常返回后的 lock cleanup。
- **修复建议：** 使用有 owner metadata 的 lock（PID、host、进程启动标识/nonce），仅在可证明
  owner 已死亡或租约超时后安全回收；或者改用 OS 会在进程退出时释放的 advisory lock。必须加
  crash/stale-lock 回归，不能无条件删除一个仍可能被活进程持有的锁。
- **末次复核结果：部分解决，P1 未关闭。** `epub-reader-store.el:166-324` 增加 PID、host、
  process start、nonce、ownerless grace 和 quarantine rename；普通同主机 dead PID 探针能接管、
  持久化且无 lock 残留，live-owner 顺序测试也会拒绝接管。可是
  `--reclaim-stale-lock` 在 `:269` 先判断旧 lock stale，随后到 `:281` 才按 pathname rename；
  两步没有绑定读到的 owner nonce。确定性 ABA 探针在两步之间移走旧孤儿锁并安装有效的
  live-owner 锁，原 contender 仍将新锁 rename/delete、成功 flush，`new-live-lock-survived=nil`。
  现有 `test/epub-reader-store-test.el:151-221` 都是顺序场景。接管必须通过能把回收动作原子绑定
  到原 owner identity 的锁/lease/CAS 机制；补双 contender 交错测试。异主机 owner 当前永久
  视作 alive（`:227-248`）也意味着共享目录上的远端宿主崩溃仍无法自动恢复。
- **最终复核结果：仍为部分解决，P1 未关闭。** `epub-reader-store.el:255-345` 现在 capture
  directory file-identifier、owner nonce 与 mtime；两方 ABA 原探针正确得到 outer=nil，
  `new-live-owner` 保留；相同 file-identifier 但 nonce/ownerless mtime 不同也均判为不同 instance。
  但 `--reclaim-stale-lock` 仍在 `:326` 先按 pathname 搬走 canonical lock，到 `:330-344` 才后验
  identity 并尝试放回。第三 contender 可在这个空窗 `mkdir` canonical；确定性交错探针得到
  canonical owner=`third-live`、quarantine owner=`replacement-live` 且 restore 报错，原
  replacement owner 与第三 owner 可并行进入事务。新增两方测试
  `test/epub-reader-store-test.el:257-296` 没覆盖此分支。应使用 OS advisory lock、真正 CAS，或
  一个不会在 owner 校验前暴露空 canonical pathname 的共同仲裁锁，并增加三方回归。异主机
  owner 永久视作 alive 的保守策略也仍只有内联注释，公开使用共享 store 前需文档化。

### S-02 — P2 建议：有 schema 检查，但没有 migration 路由

- **位置：** `epub-reader-store.el:40,52-70,91-119`；蓝图
  `docs/architecture.md:52-53,241-245`。
- **问题：** 任何非 schema 1 都统一视作 invalid/unsupported。未知/较新 sidecar 会保留且
  禁止覆盖，这是安全的；但旧版本也没有显式迁移函数或“已知 legacy，拒绝恢复”的分支。
  当前是首个 store schema，暂未造成已发布数据损失，但不满足蓝图把 migration 归属 Store
  的接口承诺。
- **证据：** 写入结构相同的 schema 0 后，open 只返回 warning，load=nil，flush 被禁止；测试
  `store-test.el:51-71` 只覆盖 schema 999/corrupt 保留。
- **修复建议：** 建立 `schema -> migration` dispatcher，并区分 older-migratable、legacy
  locator identity、newer-unsupported；若第一版明确没有可迁移格式，也应写成显式 policy 和测试。
- **最终复核结果：已解决。** `epub-reader-store.el:78-95` 已明确区分 malformed、current、
  older-no-migration 与 newer-unsupported；`test/epub-reader-store-test.el:77-91` 锁定 schema 0
  的保留/拒绝行为。当前 sidecar schema 1 是首个公开格式，没有可实施的旧数据迁移，因此这一
  显式 policy 足以关闭原 P2；未来新增 schema 时仍必须增加真实 migration。

### S-03 — P2 建议：保存 timer 是周期 idle flush，不是位置变化 debounce

- **位置：** `epub-reader-ui.el:540-556`；蓝图 `docs/architecture.md:246-248`。
- **问题：** effect 创建 `run-with-idle-timer ... t` 重复 timer；每次 callback 都重新 stage
  当前 locator 并 flush。它没有在 point/locator 改变后重置一次性 timer，长时间静止阅读仍可能
  周期写 sidecar。
- **修复建议：** 位置变化只标 dirty 并重置一次性 idle timer；flush 后未变化则不再写。
  chapter switch/kill 仍同步 flush。测试计数一次静止 idle period 内的实际 rename 次数。
- **最终复核结果：已知限制属实，但不接受响应文档的非阻断定性。**
  `epub-reader-ui.el:588-605` 仍传 `repeat=t`，独立探针也观察到 `t`。更重要的是 callback 和
  kill 都不是单纯 flush，而是重新捕获/stage 并刷新 `:updated`；所以它不仅增加 I/O，还会让
  一个未移动的 stale buffer 覆盖另一 buffer 的新位置，已经参与构成 S-01。只有引入位置
  dirty state、一次性 debounce，并避免未变化时重发 capture timestamp 后，才可降回纯性能 P2。

### T-01 — P1 应修：TOC `q` 后重开丢失选中行

- **位置：** `epub-reader-ui.el:129-133,1010-1023,1055-1077`。
- **问题：** refresh 会按稳定 row key 恢复 point，多级 collapsed state 也留在 TOC
  `textui-state`；但 `q` 直接绑定 `quit-window`，重开 existing buffer 只 `display-buffer`，没有保存
  或恢复 row/window-point。side-window quit/reopen 后 point 落到无 row property 的尾部。
- **证据：** `0/0` 的折叠/展开正确，选中 `0/0/0` 后 `q`，重开 row key 为 nil。
  `ui-test.el:350-398` 覆盖 refresh 内的 row 保持和当前章 face，没有覆盖真实 quit/reopen。
- **修复建议：** 用 reader 自己的 TOC quit 命令，在 UI state 保存 selected row key；重开
  display 后按 key 设置 buffer point 和 window-point。若 key 因折叠不可见，回退最近可见祖先或
  当前章节。
- **最终复核结果：已解决。** `epub-reader-ui.el:1074-1130,1162-1198` 保存稳定
  `:selected-key`，自定义 quit 隐藏所有 TOC windows，重开后恢复 buffer/window point，并有祖先、
  当前章和首行回退。新增测试 `test/epub-reader-ui-test.el:498-522` 通过；独立真实隐藏/重开探针
  的两处 row key 均为 `0/0/0`。

### G-01 — P1 应修：全书百分比忽略块内 offset，且书末达不到 100%

- **位置：** `epub-reader-ui.el:185-198,276-329`。
- **问题：** 章节权重取 XHTML 文件 byte size；章内比例却只用 `block-index / block-count`，
  完全忽略块长和 locator offset。一个单块章节从首字到末字百分比不动；最后一块最多是
  `(N-1)/N`，所以全书最后 source 字符仍小于 100%。已缓存的 `character-count` 没有被使用。
- **证据：** fixture 末字为 95.734337%；首章第一个 block 的首尾均为 0%。现有
  `ui-test.el:400-412` 只断言跳到下一章后百分比增加。
- **修复建议：** 明确定义 progression 权重。至少缓存每章 block 字符前缀和，以
  `(前块字符 + locator offset + endpoint convention) / chapter-character-count` 计算章内比例；
  书首固定 0、最后可读字符/EOF 固定 100，并覆盖空块、图片块、单块章和极端块长差异。
- **最终复核结果：原 P1 已解决。** `epub-reader-ui.el:216-253,339-380` 缓存 block 字符前缀并
  纳入 source offset，测试 `test/epub-reader-ui-test.el:538-560` 锁定 0/块内变化/100 endpoint；
  独立探针得到 `0.0 -> 9.091098 -> 100.0`。残余 P2 是章节权重仍取 XHTML 文件 byte size
  (`epub-reader-ui.el:303-312`)，且蓝图 `architecture.md:52,230,272` 把 progression 归 Locator，
  生产实现却仍在 UI；这不影响本次明确要求的“书末 100%”关单，但下一阶段应把权重语义和模块
  owner 收口。

### X-01 — P2 建议：chunk range 进入 effect 依赖，违反蓝图的显式约束

- **位置：** `epub-reader-ui.el:528-538`；蓝图 `docs/architecture.md:248`。
- **问题：** post-render effect 的 dependency list 包含 `start/end`，而蓝图明确规定
  chunk state 不能成为 effect 依赖。当前 region refresh 不 reconcile effect，尚未复现资源泄漏；
  但 full refresh 与 chunk 状态交错时会形成不必要的 effect 身份变化。
- **修复建议：** post-render 工作继续由 region refresh 后的显式调用完成；full render effect
  只依赖真正决定其生命周期的 reader/session identity 与 width，不依赖 chunk range。
- **最终复核结果：已解决。** `epub-reader-ui.el:579-587` 的 post-render dependency 只含
  spine index 与 available width；`test/epub-reader-ui-test.el:296-305` 明确断言不含 chunk range。

### X-02 — P2 建议：session 内镜像了 current chapter 与 cache 中的同一组字段

- **位置：** `epub-reader-ui.el:81-91,200-225`。
- **问题：** X-02 的跨 TextUI boundary 已经收口，但 session 同时保存
  `section/blocks/block-index/anchor-index`，`dom-cache` 中的 `chapter-data` 又保存同一组对象。
  `--load-chapter` 每次手工同步四个 slot；这是一个低风险的 Duplicated State/Data Clumps
  判断项，后续若增删 chapter metadata，容易只更新一侧。
- **修复建议：** session 只保存 `current-chapter-data` 和 chapter cache；section/blocks/indices
  统一通过 chapter-data accessor 读取，避免两套“当前章”真相。
- **最终复核结果：已解决。** session 现只持有 `current-chapter`，section/blocks/indices/prefixes
  统一经 chapter-data accessor 读取（`epub-reader-ui.el:174-203,233-253`），reader
  `textui-state` 仍只含 UI 字段。复查生产代码也未发现 `textui--*` 私有调用。`--index-blocks`
  返回四元素 list 再 `nth`（`:216-250`）仍是低风险 Data Clumps smell，但不是重复 session 真相。

## Standards

最终 Standards 轴仍只复核 S-01/S-04。S-01 已符合 `architecture.md:246-247`：位置变化时
冻结 timestamp，后续生命周期只 flush snapshot，未发现相关 smell。S-04 在 rename 后后验
identity 虽防止删除 replacement，却会短暂移走活锁，使第三 contender 能取得 canonical，仍
硬违反 `architecture.md:247` 的事务互斥。`epub-reader-store--stale-lock-p`
(`epub-reader-store.el:302-305`) 当前无调用，是 Low Middle Man/Speculative Generality 判断项。

## Spec

最终 Spec 轴仍只复核 S-01/S-04。S-01 完整满足 dirty-old 逆序保存规格。S-04 满足普通 orphan、
顺序 live owner、两方 ABA 与 inode 重用防护，但未保持接管全过程互斥：replacement 被搬走到
恢复之间第三 contender 可获得 canonical。异主机 owner 永久 alive 仍只有内联注释，没有公开
policy/回归。未发现两项之外的 scope creep。

双轴摘要：Standards 1 个 High、1 个 Low smell；Spec 1 个 High、1 个 Low policy 缺口；
最严重项均为 S-04 的三方恢复空窗。

## 已验证通过

- chunk shift 后每个可见 window 的 locator 与 visual row 都能恢复；双 window 长段探针通过。
- chapter cache 的 canonical blocks 无逐字符 source properties，只有当前 rendered chunk 附属性。
- sidecar temp 与目标同目录，写前 mode 0600，rename 后没有残留 `.tmp-*`；corrupt/newer 文件
  会保留，不会被静默覆盖。
- 正常进程内竞争时，sidecar lock 覆盖完整 read/merge/write/rename 事务；失败方 pending 可重试。
- 未移动的旧 reader 晚关闭不会再覆盖新位置；同主机 dead PID 和过期 ownerless lock 的顺序
  接管可完成，已有有效 live owner 的顺序场景会拒绝接管。
- 两个 reader 都移动时，先移动但后关闭的 reader 不再覆盖更新位置；两方 ABA replacement
  会按 nonce/file-identifier 被识别并恢复，inode 重用 guard 的独立比较探针通过。
- exact 与 degraded restore 都写入 `:restore-quality` 并分别用 message/warning 提示；
  `test/epub-reader-store-test.el:73-120` 的端到端路径通过。
- TOC 多级 flatten/fold、collapsed state、当前章节 face、跨 spine 跳转以及 `q`/重开选中行通过；
  正文关闭会清理 TOC buffer。
- 第一章 previous、空 history back、第一章 scroll back、末章 next、末章 scroll next 都会报
  明确边界错误，且不会改变 spine state/history；正常 history back/forward 使用 locator。
- 书首、块内 offset 单调变化与最后 source 字符 100% 均通过。
- X-02 的核心边界已收口：publication/section/blocks/cache/store 均在 buffer-local session，
  reader TextUI state 只有 UI 字段；TOC state 只有 collapsed UI 状态。生产代码未调用
  `textui--*`/`textui-kp-core--*` 私有 API。

## 测试质量

实现者报告 76/76；最终复核按用户限定运行本轮两条新增 ERT，**2/2 通过**。新增测试已准确
转化上轮 dirty-old 和两方 ABA 反例。S-04 仍漏一个决定 Gate 的后继交错：

- `test/epub-reader-store-test.el:257-296` 验证 outer 识别 replacement 后能把它放回，但没有在
  outer 已搬走 replacement、准备 restore 前让第三 contender 取得 canonical；也没有锁定异主机
  orphan 的保守 policy。

其他测试本轮未重跑或重新评价。

## Gate 结论

**Gate 未解除，不可进入下一阶段。** S-01 已关闭；唯一剩余阻断项是 S-04：接管必须在不移走
活 canonical lock、不暴露可被第三方 `mkdir` 的空窗前提下原子绑定原 owner identity。修复后
必须通过三 contender 回归：replacement owner 在 outer 误搬/识别期间始终保持唯一事务所有权，
不得遗留 live lock 于 quarantine。异主机 orphan policy 应同时明确。

其他 finding 本轮未复核；S-04 一个 P1 已足以维持 Gate。
