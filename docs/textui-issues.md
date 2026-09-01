# TextUI 集成问题记录

以下问题均只用 TextUI 公开 DSL 复现。reader 没有 advice 或调用 TextUI 私有函数；通用的
native image 缺陷已直接在 TextUI 修复，reader 只保留调用方拥有的显示策略。

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
消除调用者 buffer 的额外行距。Emacs 的 `line-spacing` newline property 只能把行距扩大到高于
buffer/frame 默认值，数值 0 或 `(0 . 0)` 都不能把继承的正行距压回零。

单独给图片 newline 设置 `line-height=t` 仍不足以抵消 buffer 正行距：可见 glyph 在处理 newline
前已经把 extra spacing 累计到该视觉行。Emacs 31 图形探针得到图片/正文均为 17px，而临时移除
buffer spacing 后同一图片行为 14px。

reader 的像素级规避是保存用户设置，把 reader buffer 的基础 `line-spacing` 置 0，再通过公开的
newline `line-spacing` property 把原值逐行加回全部非图片行；图片行只使用 `line-height=t`。
mode 关闭时恢复原来的 local/inherited 状态。图形回归得到图片 **14px**、普通正文 **17px**，并
确认 letterbox 后的 caption 不带 image row 属性。这样改变的是实现载体，不改变正文看到的用户
行距。

建议 TextUI 后续明确 `:image` 对非 nil `line-spacing` 的契约，或为 image leaf 提供公开的
行度量/行距策略；当前这部分仍由 reader 的显示策略负责。

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

## 4. native `:image` 的 alt、property 与 letterbox range（TextUI 已修复）

旧 native 路径用 `(make-string width ?\s)` 构造 unibyte 行，再用 `store-substring` 写入 alt。
中文 alt 因此报 `Attempt to store non-byte value into unibyte string`；ASCII 即使能写入，
`store-substring` 也只复制字符，不复制 reader 放在 alt 上的 image anchor property。

TextUI 提交 `0a89825` 先把 native slice 行改成 multibyte，并用属性保真的字符串拼接嵌入 alt。
后续提交 `1075b6d` 又关闭两个边界：alt 同时按显示宽度与底层字符槽截断，combining mark 与
variation selector 不再令 splice 越界；带属性的空白 carrier 固定在 image leaf 第 0 行，实际
slice 即使因小图 `top>0` 后移，也不会让 reader 的固定行数标记越过 leaf 并污染 caption。

TextUI 回归覆盖 CJK property round-trip、20 个 combining/variation 字符的 10 列 leaf，以及
20×20 SVG 在 4 行 leaf 中的 letterbox；reader 图形 fixture 同时验证 14px 图片行、17px 正文行和
caption range。生产 reader 仍只通过公开 `:alt` 搬运 source anchor，没有调用 TextUI 私有 API。
