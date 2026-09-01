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
| 改造后：中央目录 preflight + 按需 materialize | 0.274640, 0.309134, 0.356037, 0.351302, 0.357216 | 0.351302 s | 6 |

中位数减少 69.6%，约为改造前的 3.29 倍速度。首屏只 materialize：
`mimetype`、`META-INF/container.xml`、`content.opf`、`toc.ncx`、`cover.xhtml` 与
`cover.jpg`。若 store 恢复到其他章节，则以该章节替代 `cover.xhtml`，并仅展开它当前
chunk 内实际进入 `:image` leaf 的图片。

## 实现结论

- `epub-reader-container-open` 仍对整个中央目录执行路径、清单、大小与压缩比 preflight，
  但不再解压全部成员。
- `epub-reader-container-materialize-member` 逐成员流式读取，复用 preflight 结果、实际字节
  限额与同容器缓存；失败文件不会发布到最终路径。
- OPF/nav/NCX、spine XHTML 和图片都由 publication/renderer 在第一次实际使用时请求。
- 全书进度的 spine 权重来自中央目录声明的未压缩 size，不要求 XHTML 已经落盘。
