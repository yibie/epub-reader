# 第二阶段审计修复响应

日期：2026-08-31

## 已关闭

- V-01：viewport 同时保存每个 window 的 point locator、top locator 和视觉行；优先恢复 top locator，缺失时用 `vertical-motion` 按视觉行回退。覆盖窄窗、2,000 字符不可断长行和同 buffer 双 window。
- V-02：chapter cache 只保存规范文本与 block metadata。`epub-reader-render-block-element` 仅为当前 chunk 的副本逐字符附加 source/book/spine 属性；chunk 外 block 没有 locator 属性。
- V-03：前后 guard 都采用包含端点的距离判断，并覆盖等于 guard 与 guard=0。
- S-01：stage 时记录位置时间；sidecar 级独占锁覆盖 read/merge/write/rename；旧 handle 晚 flush 不会覆盖更新位置，失败仍保留 pending 供重试。
- S-02：schema dispatcher 明确区分当前、旧版无迁移和较新不支持。当前是首个已发布 schema，因此 schema 0 明确保留且拒绝覆盖，不臆造迁移。
- T-01：TOC UI state 保存稳定 row key；`q` 隐藏所有 TOC window，重开后恢复 buffer point 与 window point；不可见 key 回退到最近可见祖先或当前章节。
- G-01：chapter data 缓存字符前缀和；百分比使用 block 前缀、locator offset 与字符端点约定，书首为 0%，最后可读字符为 100%。
- X-01：post-render effect 依赖只含 spine index 与宽度，不含 chunk range；region refresh 继续显式执行 post-render。
- X-02：session 只持有 `current-chapter` 与 chapter cache；section/blocks/indices 统一从 chapter data 读取。

## 已知限制

- V-04：`epub-reader-chunk-max-characters` 仍是软预算；单个超长 semantic block 至少完整进入 chunk。这与当前稳定 block locator 模型一致。硬切片需要定义跨 slice 的 source offset、链接/face/property 切分和 kinsoku 行为，留到 oversized-block 专项，不把软预算描述为安全内存上限。
- S-03：当前仍是周期 idle flush，不是位置变化触发的一次性 debounce。换章与 kill-buffer 的同步保存正确，store 的时间比较也避免旧位置回退；减少静止阅读写入次数留到输入/dirty-state 生命周期专项。

