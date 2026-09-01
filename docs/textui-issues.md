# TextUI 集成问题记录

以下问题均只用 TextUI 公开 DSL 复现。reader 没有 advice 或调用 TextUI 私有函数；当前
规避都留在 reader buffer 的显示策略中。

## 1. `:image` 继承正 `line-spacing` 后出现切片缝隙

最小复现：

```elisp
(setq-default line-spacing 0.25)
(textui-open
 "*textui-image-spacing*"
 (lambda (width)
   (list (list :type :image :file "/tmp/tall.jpg" :rows 16
               :alt "image" :layout (list :width width)))))
```

现象：16 条 native slice 之间出现背景色横缝；连续图片靠近窗口底部时，TextUI 按普通
`frame-char-height` 计算的行预算也与 Emacs 的实际带行距高度不一致，容易表现为切片或相邻图片
视觉重叠。把 buffer-local `line-spacing` 设为 `nil` 后，同一样书封面连续、章末连续图片也不再
重叠。

源码定位：TextUI 的公开 `:image` leaf 在 `textui--render-image-spec` 中按
`frame-char-height` 计算 `image-rows`，再用 slice display spec 分到普通文本行；它没有接收或
消除调用者 buffer 的额外行距。单纯在 slice 字符上补 `line-spacing=0` 仍不能稳定覆盖继承的
buffer 值。

reader 规避：启用 `epub-reader-ui-mode` 时把 buffer-local `line-spacing` 设为 `nil`，段落间隔
继续由 TextUI frame 的显式 `:gap` 表达；post-render 还为图片行标记 `line-spacing=0`，防止后续
属性合成重新引入额外间距。

建议 TextUI 后续明确 `:image` 对非 nil `line-spacing` 的契约，或为 image leaf 提供公开的
行度量/行距策略；在此之前 reader 不修改 TextUI。

## 2. 已物理折行的 frame 被 Emacs 再次软折行

最小复现：让 `:text` 输出一段带 CJK、窄标点和不可分 URL 的满宽行，并在 TextUI buffer 中
设置 `truncate-lines=nil`。窗口像素宽度、variable-pitch glyph 与 TextUI cell 宽度处在边界时，
Emacs 会再次软折行；续行的单个 CJK 字或 continuation bitmap 会落到居中栏外，看起来像左侧
竖排漏字。

reader 规避：TextUI 已负责物理折行，因此 reader 设置 `truncate-lines=t`，并在本 buffer 隐藏
`truncation`/`continuation` fringe bitmap。样书中“丁锋/灭顶”等段落复测后，左侧单字列消失，
居中栏没有被 spacer 外的续行侵入。

建议 TextUI 文档明确：消费完整 frame 的 buffer 应避免 Emacs 二次 soft wrap；若框架希望统一
保证这一点，可在公开 mode 契约中提供对应选项。
