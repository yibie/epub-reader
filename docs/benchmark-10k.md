# 10k 段 viewport 基准

基准 fixture 为 `long-chapter.epub`：第一章含一个标题和 10,000 个带稳定 id 的段落。运行命令：

```sh
emacs -Q --batch \
  -L /Users/chenyibin/Documents/emacs/package/textui \
  -L . -L test -l test/benchmark-10k.el
```

2026-08-31 本机结果（100 次 chunk shift，32 blocks / 4,000 chars 双预算）：

| 指标 | 每次平均 |
|---|---:|
| chapter producer | 0.037 ms |
| region layout + commit（含 producer） | 37.787 ms |
| batch `redisplay t` | 0.004 ms |

完整 chapter cache 含 10,001 blocks，但初始 frame 和每次 region refresh 最多只生成 32 个 block leaf。按尾部 anchor 跳转通过 hash index 定位，没有生成或线性扫描前 9,999 个 TextUI leaf。数字只用于本机回归，不作为跨机器性能承诺。
