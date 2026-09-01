# 性能终审响应

日期：2026-09-01。对应 `docs/audit-perf.md`。

## P1 关闭情况

- R-01：删除跳过 reader view-state 的交互 refresh 分支。任何改变 source-order 的 chapter
  region refresh 都捕获并恢复 locator、各窗口 visual row；只缩小现有覆盖的 guard shift 直接
  跳过。财新原探针由 offset `20→117`、进度变化，修复为 offset `20→20`、进度不变。
- T-01：`textui-text-layout-cache-size=0` 现在绕过 lookup/store 并直接调用 planner；balanced 与
  greedy 的正文和 source properties 均有回归。
- T-02：cache key 加入相关 named face 的解析后 metric、frame font 与 display generation；主题
  enable/disable 和 frame font hook 自动递增 generation，直接 fontset 变更可调用公开的
  `textui-invalidate-text-layout-cache`。
- T-03：采用“greedy 补齐 justification”。`:wrap` 只决定 greedy/KP 断点选择，两者复用同一
  display-glue 分配，对可行的非末行两端对齐。TextUI ADR 0036 与两仓库契约测试锁定该语义。

## P2 决定

- A-01 已处理：TextUI ADR 0036 记录 break strategy、alignment、CJK/property 保证和 cache
  invalidation；本项目 `architecture.md` 已同步。
- P-01 暂不扩成可抢占调度器。预取仍在 Emacs 主线程，0.121--0.324 秒成本与命中延迟继续在
  `perf-notes.md` 分列；后续应拆 materialize/parse/block 三个可让出 idle 阶段。
- D-01 暂列已知开发缺口：现有 `test/benchmark-10k.el` 可复跑 viewport，但财新换章/redisplay
  harness 与原始 TSV 尚未入仓。下一轮应增加接受任意 `EPUB_SAMPLE` 的无版权脚本及合成多章
  fixture，不能提交私有样书。
- A-02 暂缓结构化后台 job；现有裸 list 没有造成此次正确性问题。若再增加 job kind 或字段，先
  改为 `cl-defstruct`，并统一校验 buffer/session/generation，再扩展调度。
