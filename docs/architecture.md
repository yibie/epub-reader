# EPUB Reader 架构：自研领域层，TextUI 承担 UI 与布局

> 状态：已拍板的实现方向，取代 `discussion-design.md` 的 nov 增强路线。
> 基线：Emacs 29.1+、TextUI 0.5.1+；第一版只支持无 DRM、可重排的 EPUB 2/3。

## 0. 架构结论

本项目自建 EPUB container、publication、语义 renderer、持久 locator 和 store；阅读 buffer、响应式宽度、文本折行、图片适配、刷新、临时 focus 恢复与资源生命周期交给 TextUI。

```text
EPUB file
  -> container：安全解包/成员访问
  -> publication：metadata + manifest + spine + TOC + section DOM
  -> renderer：DOM -> 语义 block -> TextUI interface frame
  -> TextUI：width -> Flex/Grid/:text/:image -> Emacs buffer

locator <-> renderer/source properties <-> store
reader-ui 编排以上模块，并拥有正文/TOC buffer 与窗口策略
```

关键取舍是：**不写 CSS/浏览器引擎，也不把整本书变成一个巨大 frame。** Renderer 只实现书籍常用的语义白名单；长章只向 TextUI 提交当前位置附近的一段语义块。

## 1. TextUI 能吸收什么，不能吸收什么

已通读 TextUI 的 README、CONTEXT、`textui.el`/`textui-kp-core.el`、全部 examples 和 ADR。这里以源码行为为准。

TextUI 已提供：

- `textui-open` 的稳定 buffer、buffer-local `textui-state` 和宽度变化后的自动全量刷新；
- Flex/Grid 的宽度分配，以及 `:text` 的像素测量、Knuth–Plass 折行/对齐；
- `:image` 的等比 fit、居中和逐文本行切片；
- full refresh 时对 native element、layout cell 和 `:text` source offset 的 point/window-start 恢复；
- 完整行 column region 的同步/合并刷新；
- `textui-effect`、`textui-async-callback` 和 kill-buffer cleanup 的生命周期协调。

TextUI 明确不负责：

- ZIP、XML/XHTML、EPUB 规范、URL/资源解析和任何领域数据；
- 窗口高度分配、viewport 选择或多 buffer application shell；
- EPUB 的持久位置、书籍指纹、进度文件、bookmark 或 annotation；
- CSS cascade、段落语义、face 策略、链接动作和图片应占多少行。

因此 TextUI 是 renderer 与 reader-ui 的布局/runtime 依赖，不是第七个 EPUB 领域模块。

## 2. 六模块映射

| 路线 B 模块 | TextUI 吸收的职责 | 本项目仍须自建的职责 | 深模块的主要 interface |
|---|---|---|---|
| container | buffer kill 时可替它执行 cleanup；不理解 EPUB/ZIP | 选择解包程序、列出/验证成员、路径 containment、临时目录、按需读资源、关闭 | `open`, `read-member`, `materialize-member`, `close` |
| publication | 无 | 解析 OCF/container.xml、OPF metadata/manifest/spine、EPUB2 NCX/EPUB3 nav、href/fragment 规范化、章节 DOM/cache | `load`, `section`, `spine`, `toc`, `resolve-resource` |
| renderer | 宽度分配、折行、图片切片、Flex/Grid、frame 刷新 | DOM 白名单、空白归一化、语义 block、face/source/link properties、frame/块窗口生产 | `section-blocks`, `frame`, `chapter-region-elements` |
| locator | 同一 frame 结构下，full refresh 可按 `:text` source offset 暂时恢复 point | EPUB 持久坐标、point 双向转换、块窗口切换恢复、quote/context fallback、全书 progression | `at-point`, `resolve`, `compare`, `progression` |
| store | effect/cleanup 可调度 idle save 和关闭时 flush | schema、序列化、原子写、合并、迁移、书籍指纹、恢复策略 | `load-book`, `put-progress`, `flush` |
| reader-ui | 稳定 buffer、state update、响应式 full/region refresh、widget 生命周期 | 用户命令、keymap、正文与 TOC buffer、窗口展示、spine/chunk 状态机、错误与 loading UI | `open`, `next/previous`, `goto`, `toc`, `close` |

接口是测试 seam；内部 struct、DOM 和 TextUI plist 不进入用户公开接口。用户侧第一版只需要 `epub-reader-open` 以及导航/TOC 命令。

## 3. Container 与 publication

### 3.1 Container

“自研阅读器”表示不依赖 nov，不要求第一版顺带自写 ZIP implementation。MVP 使用可配置的 `unzip` 或 `bsdtar` adapter，把格式差异藏在 container 后面；二者存在时已经是一个真实 seam。后续若有纯 Elisp ZIP reader，再作为第三个 adapter，而不是改 publication。

Container 必须：

- 先列出并验证成员名，拒绝绝对路径、drive prefix、NUL 和规范化后含 `..` 的路径；
- 设置单成员/总解压大小和压缩比上限，拒绝 zip bomb；
- 只写入 `make-temp-file` 创建的专属目录，materialize 后再次检查 truename containment；
- 不执行 EPUB 内容，不自动联网；
- 返回显式 `close`，reader-ui 用 `textui-register-cleanup` 保证 buffer 被杀时删除临时目录。

### 3.2 Publication

Publication 是最深的领域模块。它把 EPUB2/3 差异消化成同一个只读 book model：metadata、按 reading order 排好的 spine、树形 TOC、manifest resource 和延迟 section loader。

- XML 首选 Emacs 内建 libxml；解析 XHTML 时保留 `id`、`href/src`、`xml:lang` 和语义标签。
- 所有 href 先 percent-decode/规范化，再相对 OPF 或当前 section 解析；fragment 与文件路径分开处理。
- Section DOM 按 spine item 懒加载；DOM 和语义 blocks 可缓存，图片只在进入可见块时 materialize。
- Publication 不返回临时目录裸路径给 UI；资源始终经 `resolve-resource`，避免 path 规则散落。

## 4. EPUB DOM 到 TextUI frame

### 4.1 两步渲染

DOM 不应直接递归生成 TextUI plist。先变成与宽度无关的语义 block 向量，再由 frame producer 选择块窗口并生成 plist：

```text
DOM node
  -> block {id, kind, normalized attributed text, children, resource, locator-base}
  -> TextUI element(s)
```

这一步提供三种 leverage：DOM 解析不随 resize 重做；locator 锚在 block 而非 DSL 序号；viewport 可以切语义块而不是切渲染后的 buffer 行。

### 4.2 Frame 外形与居中

TextUI 没有 `max-width`/`justify-content:center`，renderer 用 render function 收到的 `width` 计算左右 spacer 和正文宽度。正文 refresh region 必须占完整行，不能把 `:refresh-id` 直接放在水平 row 的中间列；正确外形是“全宽 region 包住内部居中 row”：

```elisp
((:type :flex :direction :column :gap 0
  :children
  (STATUS-ELEMENT
   (:type :flex :direction :column :gap 0
    :layout (:refresh-id chapter)
    :children
    ((:type :flex :direction :row :gap 0
      :children (LEFT-SPACER CENTERED-CONTENT RIGHT-SPACER)))))))
```

`chapter` region 的 producer 接收当前全宽，再重算 spacer/正文栏；这样 region 仍是一段完整 buffer lines，符合 TextUI 的公开约束。正文默认目标宽度建议 72 cells，窄窗时取可用宽度。

### 4.3 标签映射与 face

| EPUB 语义 | TextUI 映射 | 策略 |
|---|---|---|
| `p` | 一个 `:text` leaf | 归一化 HTML 空白；段间距由外层 column `:gap` 控制 |
| `h1..h6` | `:text` leaf | 继承 `epub-reader-heading-1..6`，使用 weight/height/foreground，不硬编码背景 |
| `em/strong` | 同一 attributed string 的局部 face | 与 block face 叠加，不能覆盖标题/引用基础 face |
| `blockquote` | 带 padding/border 的 column，内部为 `:text` | 使用 `epub-reader-quote`，MVP 不模拟 CSS 左边框 |
| `pre/code` | fixed-pitch 的 `:text`，保留 hard newline | 允许折行以避免横向丢失；不做语法高亮和 CSS white-space 全集 |
| `ul/ol/li` | bullet/序号 `item` + 可增长的 `:text` row | label 是 atomic native leaf，正文负责折行；嵌套层级限制缩进上限 |
| `a`/脚注引用 | `:text` 内的 `keymap`、`mouse-face`、`help-echo`、href property | 不把 inline link 拆成 widget；RET/鼠标由 reader keymap 读取 property |
| `img/figure` | `:image` + 可选 `:text` caption/alt | reader 按图片比例与正文宽度计算 `:rows`；TextUI 负责 fit/切片 |
| 简单 `table` | `:grid` 或逐行文本 fallback | MVP 只支持规则小表；rowspan/colspan/复杂表格明确降级 |
| 未知/容器标签 | 递归子节点或可诊断跳过 | 脚本/style 不执行、不显示；不能静默吞掉正文文本 |

所有 face 由本包定义并允许 Customize：body、六级 heading、quote、code、link、caption、muted、error。Publisher CSS 在 MVP 只提供少量语义提示，不控制盒模型、字体文件或页面背景。

当前 `:text :wrap` 只选择断点算法：reader 默认 `greedy` 以线性策略选择最远合法断点，用户可切回
`balanced` 的 Knuth--Plass 全段优化；两者随后都对可行的非末行做像素级两端对齐。它没有
`:justify nil`。若长标题或代码 prototype 证明需要 ragged alignment，应在 TextUI 另加正交的
alignment capability，不能复用 `:wrap` 含混表达，也不能在本包 advice `textui-kp-core`。决策见
TextUI ADR 0036。

### 4.4 图片行数

`:image` 要求 caller 指定正整数 `:rows`，TextUI 不分配高度。Renderer 在已知正文列宽后读取 source pixel size，按比例计算：

```text
rows = clamp(min-rows,
             ceil(min(source-width, content-pixels) / aspect / char-height),
             max-image-rows)
```

TextUI 随后再次保证不放大超过源图、保持比例并居中切片。无法读取的图显示 alt/caption 和资源错误；SVG/WebP 能力以当前 Emacs build 为准。

## 5. 长章节性能

### 5.1 不渲染整章

TextUI 的 10k K9s demo 证明的不是“10k 个 leaf 全量刷新很快”，而是：**可以缓存 10k 条领域记录、只切可见 slice，并用完整行 region 替换小窗口。** EPUB 应复用这个原则，不能照搬固定行高。

每章解析成 block vector，但 frame 只包含当前 block window：

```text
chapter blocks: [0 ........................................ N)
rendered chunk:              [start .... end)
                             ^ overscan: 约 3～5 个窗口高度
```

- 初始 chunk 围绕恢复 locator 建立；无进度时从 block 0 开始。
- chunk 用“最大 block 数 + 最大归一化字符数”双预算，例如 64 blocks / 24k chars；单个超长段落至少独立纳入。
- 普通滚动完全使用 Emacs buffer，不刷新；point 接近 chunk 前后 guard（约一屏）时，按块扩展/滑动窗口。
- chunk shift 更新应用 state，然后用 `textui-update :region 'chapter :producer ...` 或 `textui-refresh-region` 只替换 chapter region。
- 窗口宽度变化由 TextUI full refresh 处理，但它只重排当前 chunk，而不是全章。
- DOM、block 和 materialized resource 缓存按 `(book-key, spine-href)`；TextUI 在单个 reader
  buffer 内按 attributed text、像素宽度、wrap 策略、解析后 face/font 与 display generation
  缓存段落布局，不跨不兼容的宽度、主题或字体复用。

### 5.2 Viewport 与 point

TextUI render function 只接收 width，不负责 height。Reader-ui 像 K9s demo 一样读取显示该 buffer 的最小 `window-body-height`，但只用它确定 overscan/guard，不假装精确分配每个 variable-height block。

Full refresh 且 block 顺序不变时，TextUI 会按 `:text` 的内部 source offset 恢复 point 和 window-relative row。Chunk shift 改变了 source-order，且 `textui-refresh-region` 会省略局部 location IDs，所以本包必须在 region refresh 前捕获自己的 locator 与 viewport row，刷新后 resolve locator，再恢复 `window-point/window-start`。不能把 K9s 的“相对行列恢复”当成 EPUB 语义恢复。

性能验收至少包含一个 10k 段 fixture：打开只生成预算内 leaf；到章末的跳转不遍历/渲染前面所有 leaf；连续 100 次 chunk shift 记录 producer、布局和 redisplay 前耗时。数字作为回归基线，不宣传成跨机器保证。

## 6. CJK 折行责任

### 6.1 源码结论

TextUI `:text` **不读取** `word-wrap-by-category`，也不调用 Emacs `kinsoku.el`。调用链是：

```text
textui--wrap-text
  -> textui-kp-core-greedy-lines / textui-kp-core-justify-lines
  -> textui-kp-core--split-boxes / --break-forbidden-p
```

其 vendored core 自己：

- 把 Latin word、CJK character、space 分 box；
- 用 Unicode general category/char syntax 识别常见开闭标点；
- 用固定 `no-line-start`/`no-line-end` 表和 NBSP/word-joiner 表禁止部分断点；
- `greedy` 线性选择最远合法断点，`balanced` 用 Knuth--Plass 全段选断点；两者在 CJK/Latin
  gap 插入同一套 display-only glue，对非末行两端对齐。

所以第一版 CJK 折行由 **TextUI core** 负责；设置 `visual-line-mode`、`word-wrap-by-category` 或 `kinsoku` 对已经由 `:text` 产出的硬行不起作用，也不应叠加第二套折行。

### 6.2 缺口方案

现有实现是“common kinsoku”，不是按 `lang=zh/ja` 的完整排版标准。MVP 先以真实 fixture 验证简中、繁中、日文、中英混排、全角标点、引号/括号、NBSP、emoji/combining mark 和超长 URL。

- 若规则对所有语言都明显错误，直接在 TextUI core 修通用 boxing/禁则并补其测试。
- 只有真实用例证明 zh/ja 需要不同策略时，才在 TextUI 设计一个最小的 public break-profile seam；本项目不绑定内部常量、不 advice 私有函数。
- 极窄窗口会触发 emergency spacing 或 ragged fallback；Reader 默认正文 `min-width`，避免把可读性问题交给应急算法。

## 7. Locator 如何附着到 frame

### 7.1 Text property 是否保留

答案是 **正文 source property 会保留，但合成布局字符不会继承它**。源码路径如下：

1. `:text :value` 接受带属性的 string；`textui--wrap-text` 对它 `copy-sequence`；
2. KP 以 `substring attributed` 取行，`concat`/layout composition 继续保留属性；
3. full/region commit 都用 `insert rendered` 写回，仍保留自定义属性；
4. KP 为无原始空格的 gap 插入带 `textui--synthetic-spacing` 的零宽字符，它没有 EPUB source property；layout newline、padding/border 也没有；
5. Native widget materialization可能替换 placeholder，因此正文和 inline link 必须使用 `:text`，不能依赖 widget 保留 source property。

已用带 `epub-source` 属性的中文 string 调用实际 `textui--render-frame` 验证：原字符在折行/对齐后仍带属性，合成 U+200B 和换行不带该属性。

### 7.2 本项目属性与持久 locator

DOM 归一化成 block 时，每个原始可读字符携带本包自有属性：

```text
epub-reader-source = [spine-href, block-key, normalized-char-offset]
```

只在当前 chunk 上生成逐字符 offset，内存上限由 chunk budget 控制；持久化绝不依赖 `textui--text-source-offset` 这样的私有属性。

`epub-reader-locator-at-point` 的规则：

1. 当前位置有 `epub-reader-source` 就直接读取；
2. 位于合成 spacing/newline/padding 时，在同一视觉邻域探测最近的前后 source char；
3. 位于图片 slice 时，落到相邻 caption/alt 的 figure block anchor；因此无 caption 图片也生成一个 muted alt anchor；
4. 再补 book fingerprint、element id/DOM path、quote/prefix/suffix 与全书 progression。

持久 locator 至少包含：

```text
book-key + spine-href + block-key + normalized offset
         + exact quote + prefix/suffix + schema-version
```

Resolve 顺序为 element/block exact -> quote near block -> quote in spine -> spine start，并返回 exact/degraded 状态。TextUI focus 只负责一次 UI 重排；locator 负责换 chunk、换章、重开书和未来 annotation，二者不能合并。

## 8. Store 与生命周期

- Store 使用版本化 sidecar（MVP 可用可读 S-expression），按 book-key 保存当前位置和更新时间。
- book-key 组合 EPUB identifier、规范路径、size/mtime 和一次缓存的 content hash，不能只信 publisher identifier。
- 第一阶段尚未写入 sidecar；locator schema 3 以 `book-key + spine-href` 为持久身份，数值 spine index 只作导航提示。早期 schema 2 的 publisher-only locator 明确返回 `legacy-identity`，未来 Store 不静默迁移或误恢复。
- idle debounce 保存由 render function 声明的 `textui-effect` 创建 timer；callback 用 `textui-async-callback` 绑定正文 buffer 生命周期。
- 换章前同步捕获 locator；kill-buffer cleanup 最后 flush。写入使用同目录临时文件 + rename，并在写前合并磁盘新版本。
- Region refresh 不重新 reconcile effect；chunk state 不能成为 effect 依赖。书籍切换走 full `textui-update`，让 effect 正确重启。

## 9. Reader UI 与 TextUI state

正文 buffer 的 `textui-state` 只存 UI 状态：当前 spine index、chunk range、loading/error 和待恢复 locator。Publication、DOM/block cache 和 store handle 放在 buffer-local session 中，避免每次 plist update 复制大型领域对象。

`epub-reader-open` 先创建 container/publication/session，再把初始 state 传给 `textui-open`。打开成功后注册 container cleanup、store flush、应用 keymap 和阅读 faces。用户命令：

- `n/p` 或 `]/[`：spine next/previous，捕获旧 locator 后 full update；
- `SPC/S-SPC`：普通滚动，到 chunk guard 时滑动 block window，到章尾再切 spine；
- `RET`：读取 href property，解析内部 fragment 或交给 `browse-url`；
- `t`：打开 TOC；`g`：按 TOC/title completion 跳转；`q`：关闭。

TOC 是第二个 TextUI buffer：publication tree 映射成缩进的 attributed `:text`/link rows，reader-ui 用普通 `display-buffer`/side-window 管理它，并负责正文关闭时清理。TextUI 不拥有这个 multi-buffer shell；TOC action 捕获正文 buffer，通过公开 reader-ui 命令跳转。

## 10. 项目文件结构

采用多文件；六个领域职责都足够深，塞进一个 `epub-reader.el` 会让 EPUB、布局和持久化知识混在一起。

```text
epub-reader.el                  package header、Customize、autoload、公开命令
epub-reader-container.el        archive adapters、安全检查、temp/resource 生命周期
epub-reader-publication.el      OCF/OPF/spine/TOC、href、section DOM/cache
epub-reader-render.el           DOM -> block、face/source 属性、TextUI frame producer
epub-reader-locator.el          point/locator 双向转换、quote fallback、progression
epub-reader-store.el            versioned sidecar、atomic merge/flush、迁移
epub-reader-ui.el               TextUI state、正文/TOC buffer、viewport、keymap/effects
test/epub-reader-*-test.el      按模块 interface 测试
test/fixtures/                  EPUB2/3、CJK、长章、图片、坏路径/坏 identifier
docs/architecture.md            本文
README.md / CHANGELOG.md        安装、支持矩阵、发布记录
```

生产代码只调用 TextUI public functions；不得读取 `textui--refresh-regions`、调用 `textui--render-frame` 或依赖私有 source property。需要的新能力先在 TextUI prototype 证明并加入其公开 interface。

## 11. MVP 范围

### 第一版必须有

- 打开一个无 DRM reflowable EPUB 2/3，解析 metadata/manifest/spine/NCX/nav；
- 常见文本语义、内部/外部链接、列表、引用、代码、简单图片的章节渲染；
- 居中正文栏、TextUI CJK 折行、宽度变化自动重排并保持阅读位置；
- 长章 block-window/overscan 与 chapter region refresh；
- 上一/下一 spine、章尾自动前进、history back/forward；
- TextUI TOC buffer、当前章节标识、TOC/标题跳转；
- 版本化 locator 和 idle/换章/关闭进度保存，重开恢复并报告是否降级；
- container/path/size 安全检查，错误能指出阶段和资源；
- ERT fixture 与长章 benchmark。

### 第一版不做

- 高亮、笔记、annotation UI 或 org-remark 集成；locator 先为其留 range 扩展空间；
- DRM、fixed-layout、竖排、复杂 ruby/MathML/SVG、音视频、JavaScript；
- 通用 CSS、publisher font、float/grid fidelity、精确分页；
- 全书索引式搜索、跨设备同步、EPUB CFI/Web Annotation 互操作；
- 纯 Elisp ZIP reader；MVP 的自研重点是 EPUB 模型与阅读体验。

## 12. 实现顺序

1. **Contract 与 fixtures**：固定 TextUI 版本；写 CJK 断行、source property 保留、合成 spacing、恶意路径和 EPUB2/3 最小 fixture 的验收测试。
2. **Container vertical slice**：安全解出 mimetype/container/OPF/一个 XHTML/一张图，cleanup 可证明。
3. **Publication**：统一 EPUB2/3 book model、spine、TOC、href/fragment；先无 UI 测试。
4. **Renderer + locator 同步起步**：DOM -> block -> `:text/:image`，同时写 point/locator round-trip，避免渲染完成后再补 source mapping。
5. **单章 TextUI reader**：`epub-reader-open`、居中 frame、faces、链接、宽度重排；用真实中英 EPUB smoke test。
6. **Block viewport**：chapter refresh region、guard/overscan、chunk shift 后 locator/window row 恢复；以 10k 段 fixture 测量。
7. **Spine 与 TOC**：前后章、章尾、history、第二 TextUI TOC buffer、fragment 跳转。
8. **Store**：fingerprint、versioned sidecar、effect idle save、atomic flush、exact/degraded restore。
9. **发布加固**：坏书诊断、图片 fallback、byte-compile/package-lint、README 支持矩阵和端到端回归。

第一条发布纵切是：**打开 EPUB -> 解析 spine -> 用 TextUI 渲染一个带 CJK/source locator 的章节 -> 下一章 -> 关闭重开恢复**。TOC 紧随其后；annotation 明确留到 locator 在真实书库中稳定以后。
