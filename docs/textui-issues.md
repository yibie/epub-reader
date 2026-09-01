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
视觉重叠。

源码定位：TextUI 的公开 `:image` leaf 在 `textui--render-image-spec` 中按
`frame-char-height` 计算 `image-rows`，再用 slice display spec 分到普通文本行；它没有接收或
消除调用者 buffer 的额外行距。数值 `line-spacing=0` 在部分 redisplay 路径里还可能等同于没有
override；用非 nil 的零值 pair `(0 . 0)` 才能明确压过继承的正行距。

reader 规避：不修改 buffer-local `line-spacing`，让普通正文继续继承用户设置；post-render 只给
带 `epub-reader-image-slice` 的完整物理行标记 `line-spacing=(0 . 0)`。结构回归同时检查正文没有
该 property。真实像素效果仍应在图形 Emacs、不同字体和正负 text scale 下抽样。

建议 TextUI 后续明确 `:image` 对非 nil `line-spacing` 的契约，或为 image leaf 提供公开的
行度量/行距策略；在此之前 reader 不修改 TextUI。

## 2. 已物理折行的 frame 被 Emacs 再次软折行

最小复现：让 `:text` 输出一段带 CJK、窄标点和不可分 URL 的满宽行，并在 TextUI buffer 中
设置 `truncate-lines=nil`。窗口像素宽度、variable-pitch glyph 与 TextUI cell 宽度处在边界时，
Emacs 会再次软折行；续行的单个 CJK 字或 continuation bitmap 会落到居中栏外，看起来像左侧
竖排漏字。

reader 规避：TextUI 已负责物理折行，因此 reader 设置 `truncate-lines=t`，并在本 buffer 隐藏
`truncation`/`continuation` fringe bitmap。样书中“丁锋/灭顶”等段落复测后，左侧单字列消失。
这只是阻止第二次折行和视觉泄漏，不是像素宽度正确性修复：若 variable-pitch glyph 或不可分 token
实际超过物理行，尾部会被截断而不是重新布局。

建议 TextUI 文档明确：消费完整 frame 的 buffer 应避免 Emacs 二次 soft wrap；若框架希望统一
保证这一点，可在公开 mode 契约中提供对应选项。

## 3. `:image` 的行高不读取 buffer face remap

最小复现：打开含 `:image` 的 TextUI buffer，执行 `(text-scale-set 2)`，再刷新 frame。TextUI
仍以 frame 的默认 `frame-char-height` 切片；buffer 的 `default` face remap 会改变实际文字行高，
但不会改变这个内部度量。TextUI 也只自动订阅可见 cell 宽度变化，不订阅 text scale。

reader 规避：buffer-local `text-scale-mode-hook` 同步执行完整 `textui-refresh`，用 locator 与
window view state 恢复语义 point/视觉行；生成 chunk 时只用公开的 `window-font-height` 与
`frame-char-height` 比率重算 `:rows`。同一 buffer 出现在多个 window 时取最保守（最小）的行预算。
这能让重排和 caller-owned row budget 跟随缩放，但 TextUI 内部 slice 本身仍使用 frame 默认行高；
最终像素契约最好由 TextUI 公开一个 image row metric 扩展点。
