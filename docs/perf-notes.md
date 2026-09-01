# 第三阶段打开性能记录

日期：2026-09-01。样书：`财新周刊-第22期2026.epub`（31,955,757 bytes，20 个
spine 项、164 个 ZIP 成员）。样书只读使用，未复制进仓库。

## 测量方法

- 环境：macOS，GNU Emacs 31.0.91，Apple Info-ZIP 6.00；TextUI 使用本机 checkout。
- 每次都以独立的 `emacs -Q --batch` 进程启动，关闭 progress/store，先执行一次 GC。
- 计时区间从调用 `epub-reader-open` 前开始，到 TextUI 首帧同步生成并返回 buffer 为止。
- 连续测量 5 次并取中位数；这不是冷磁盘 I/O 基准，适合比较同机同样书的实现差异。

## 结果

| 实现 | 5 次耗时（秒） | 中位数 | 首屏已落盘成员 |
|---|---|---:|---:|
| 改造前：打开即逐成员解压整包 | 1.154237, 1.236919, 1.223174, 1.125618, 1.124852 | 1.154237 s | 164 |
| `e525eef`：按需 materialize、尚无 archive snapshot | 0.274640, 0.309134, 0.356037, 0.351302, 0.357216 | 0.351302 s | 6 |
| 当前 HEAD：私有 snapshot + preflight + 按需 materialize | 0.272590, 0.277961, 0.284497, 0.284868, 0.287275 | 0.284497 s | 6 |

旧的 0.351302 秒是 C-01 snapshot 修复前的历史基线，不能再代表当前打开路径。当前 HEAD 相对
整包解压基线的中位数减少 75.4%，约为 4.06 倍速度。不同轮次受文件系统缓存影响，不应用
0.351302 与 0.284497 的差值推断 snapshot 带来负开销。

当前 5 次运行中，包裹生产 `copy-file` 测得的 snapshot I/O 分别为 0.017590、0.015269、
0.016526、0.015844、0.017329 秒，中位数 **0.016526 秒**，约占当前总中位数 5.8%；扣除该调用
后的其余 open→首帧路径分别为 0.255002、0.262694、0.267973、0.269027、0.269949 秒，中位数
**0.267973 秒**。该 snapshot 数字包含本机 APFS 与热缓存行为，不是跨机器吞吐承诺。

首屏只 materialize：
`mimetype`、`META-INF/container.xml`、`content.opf`、`toc.ncx`、`cover.xhtml` 与
`cover.jpg`。若 store 恢复到其他章节，则以该章节替代 `cover.xhtml`，并仅展开它当前
chunk 内实际进入 `:image` leaf 的图片。

## 实现结论

- `epub-reader-container-open` 先建立只读私有 archive snapshot；中央目录 preflight、book
  fingerprint 与后续 adapter 调用都绑定该快照。它仍验证整个中央目录，但不再解压全部成员。
- `epub-reader-container-materialize-member` 逐成员流式读取，复用 preflight 结果、实际字节
  限额与同容器缓存；失败文件不会发布到最终路径。
- OPF/nav/NCX、spine XHTML 和图片都由 publication/renderer 在第一次实际使用时请求。
- 全书进度的 spine 权重来自中央目录声明的未压缩 size，不要求 XHTML 已经落盘。

# 换章与滚动性能冲刺

日期：2026-09-01。以下测试继续只读使用杂志样书，并以纯文字书
`哲学小史：西方哲学四十讲 (奈杰尔·沃伯顿).epub` 作对照。

## 预算与方法

- 换章命令开始到首屏正文可读不超过 **150 ms**；图片允许随后到达。
- 连续滚动的单次命令以 **16 ms** 为理想值、**50 ms** 为工程上限。
- batch 基准在独立 `emacs -Q` 中禁用 store，每次换章前 GC，连续执行 5 次 `n` 与 40 次
  `SPC`。图形基准使用 Emacs 31.0.91 原生窗口，并在每次命令后执行 `(redisplay t)`。
- ELP 对 materialize、XHTML DOM parse、block 构建、TextUI refresh、文本规划/KP、图片
  materialize、`create-image` 与 redisplay 分段计时；sampling profiler 用来确认调用栈归属。
  下表是同一普通杂志章节的一次代表性图形运行，不把多个嵌套计时误加成总耗时。

## 优化前画像

| 阶段 | batch（秒） | 图形帧（秒） | 判断 |
|---|---:|---:|---|
| 换章总计 | 1.066969 | 3.362166 | 明显超过 150 ms |
| TextUI `refresh` | 0.948130 | 2.885674 | 主路径 |
| 文本 layout | 0.697867 | 1.984632 | 主路径中的主项 |
| KP 逐段规划 | 0.661937 | 1.929244 | 最大单一瓶颈 |
| DOM parse + block 构建 | 0.065413 | 0.206974 | 次要，仍值得预取 |
| 成员 materialize（含当前图片） | 0.034603 | 0.123538 | 次要 |
| 图片 `create-image`（6 次） | 不适用 | 0.000579 | 不是瓶颈 |
| redisplay | 不适用 | 0.131632 | 图形帧固定成本 |

杂志连续章节的 batch 换章稳定在 0.9--1.1 秒，最慢 1.067 秒；纯文字书的普通换章为
18--84 ms，但滚动自动跨章时仍出现 0.34--0.36 秒尖峰。ELP 与 CPU sampling profiler 都把
热点指向 `textui-kp-core` 的 break/optimize/measure，而非 ZIP 或 `create-image`。这也是本轮没有
先做“批量解出图片”的依据：batch 中资源解析仅约 29 ms、materialize 约 35 ms，且可以整体
移出交互路径；为它增加新的 archive 批量事务不会解决秒级停顿。

## 按画像实施的优化

1. 章节首绘同步预算缩到 2 blocks / 4,000 source chars；冷滚动 chunk 为 1 block / 3,000
   chars。首屏提交后，用生命周期绑定的 idle job 扩展到完整 viewport 预算。
2. TextUI 新增 `:text :wrap greedy`：继续使用相同 token、像素宽度和 CJK kinsoku 约束，但以
   线性 ragged-right 规划替代段落级 KP 全局优化。`balanced` KP 仍可通过 Customize 选回。
3. TextUI 对 attributed paragraph 的布局结果做 buffer-local 有界缓存；key 包含正文、text
   properties、像素宽度、wrap 策略、face remap 与 frame 字体几何。它等价覆盖
   `(book, href, width, scale)` 回看场景，同时避免 reader 缓存脱离 source properties。
4. reader 在 idle 时预取下一 spine 的成员、DOM 与 blocks，且不改变当前 chapter/session。
   正常阅读命中预取后，换章不再走 parse/block 冷路径。
5. 图片首绘为固定行数占位 leaf；idle job 才 materialize 图片，并通过
   `textui-async-callback` + `textui-refresh-region` 替换。换章与滚动同步栈不调用 unzip；后续
   chunk shift 会重新排队图片任务。单图 `create-image` 成本只有约 0.1 ms，因此暂未引入批量
   extraction API。
6. locator 的 source-block 扫描按 `buffer-modified-tick` 缓存，滚动 guard 查询改用不生成
   quote context 的轻量 source lookup。图形滚动探针中该扫描曾单次占 62.6 ms。

## 优化后同基准复测

| 样书 / 环境 | 换章到首屏 | 连续滚动 | 预算结论 |
|---|---:|---:|---|
| 财新杂志，batch 冷章节 | 最慢 0.125 s | 三轮最慢 0.034--0.037 s | 通过 |
| 财新杂志，图形帧、下一章预取命中 | 0.050 s | p95 0.039 s，中位 0.024 s | 通过 |
| 财新杂志，图形帧、刻意禁用预取的冷章节 | 0.398 s | 不适用 | 冷路径超预算，正常路径由 idle 预取隐藏 |
| 纯文字书，batch | 最慢 0.043 s | 最慢 0.021 s | 通过 |
| 纯文字书，图形帧冷章节 | 最慢 0.139 s | p95 0.015 s、最慢 0.016 s | 通过 |

财新图形连续滚动的 40 次样本有一次 56 ms 离群值；同一位置带分段计时复跑为 40 ms，未形成
稳定热点。当前稳定 p95 已低于 50 ms，但仍保留该离群值作为后续 redisplay 抖动观察项。

核心前后对比是：普通杂志章节 batch **1.067 s → 0.125 s（8.5 倍）**；实际图形阅读在下一章
预取命中时 **3.362 s → 0.050 s（约 67 倍）**。代价是图片后到、首次无 idle 机会的冷跳转仍受
DOM/block 构建约束；这两点是明确的产品取舍，而不是把同步工作藏到滚动命令里。
