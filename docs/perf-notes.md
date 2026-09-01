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
