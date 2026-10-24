# 截图流程与编辑体验问题清单

日期：2026-10-23

范围：截图入口、区域/窗口/全屏截图、滚动长截图、截图后的编辑、复制与保存，以及相关 UI 和交互。

本文是修复前的审阅快照，保留原始问题描述供回溯。问题按影响排序；当前功能以 README 为准。

## 应保留的设计

- 工具图标紧凑、工具栏密度高是优点，不应通过放大图标或增加留白来“改进”。
- 后续调整应集中在操作逻辑、状态反馈、图标语义和工具分组，保持现有的紧凑视觉风格。

## P0：会直接丢失工作

### 1. “复制成图”会关闭编辑器并清空图片

- 复制成功后主动关闭编辑器窗口。
- 窗口关闭回调会清空当前图片和全部撤销历史。
- “复制成图”还是工具栏最突出的主按钮，用户复制后若想继续编辑，未保存的工作已经丢失。
- 证据：`Sources/Rimva/App/AppController.swift:128-130`、`Sources/Rimva/App/AppController.swift:195-201`。

### 2. 新截图、导入、粘贴和关闭窗口均无未保存确认

- 新截图、导入图片或粘贴图片会直接替换当前编辑内容。
- 没有未保存状态，也没有覆盖确认。
- 直接关闭窗口或按 `⌘W` 同样会丢弃当前编辑内容和历史。
- 证据：`Sources/Rimva/App/AppController.swift:38-45`、`Sources/Rimva/App/AppController.swift:128-130`、`Sources/Rimva/App/AppController.swift:182-192`、`Sources/Rimva/Editor/EditorSession.swift:35-47`。

## P1：截图和编辑主流程存在明显问题

### 3. 选中标注时画布会跳动，随后拖动可能产生位置突变

- 未选中标注时，画布顶部留白为 28；选中标注或切换工具后变为 64。
- 同时出现的上下文工具条还会减少画布可用高度，使图片重新缩放并重新居中。
- 拖动起点按旧坐标记录，后续拖动却使用新坐标，可能产生位置突变。
- 证据：`Sources/Rimva/Editor/CanvasView.swift:62-66`、`Sources/Rimva/Editor/CanvasView.swift:124-160`、`Sources/Rimva/Editor/EditorView.swift:47-52`。

### 4. 长截图进入编辑器后几乎无法精确标注

- 画布只有适应窗口的缩放方式。
- 没有放大、缩小、实际尺寸、滚动或平移能力。
- 超长截图会被压缩成很小的预览，文字、序号和遮挡难以准确放置。
- 证据：`Sources/Rimva/Editor/CanvasView.swift:57-84`。

### 5. 文字工具在图片右侧或底部可能创建失败

- 新文字框固定向右扩展 360 px、向下扩展 54 px，再裁剪到图片边界。
- 靠近右边缘时宽度可能变成 0，靠近底边时高度可能变成 0。
- 没有反向展开或重新定位，文字框可能不可见或无法输入。
- 证据：`Sources/Rimva/Editor/CanvasView.swift:164-171`、`Sources/Rimva/Editor/CanvasView.swift:217-245`。

### 6. 长截图允许确认无效的小选区，随后直接退出整个流程

- 选区确认按钮只检查是否达到 1 px。
- 真正开始长截图时才检查选区是否至少为 `40×80`。
- 检查失败后选区被销毁并回到编辑器；提示要求扩大选区，但用户已无法在原选区上调整。
- 证据：`Sources/Rimva/Capture/CaptureSelectionView.swift:195-217`、`Sources/Rimva/Capture/CaptureCoordinator.swift:181-197`。

### 7. “自动复制”复制的是后续编辑前的版本

- 截图刚进入编辑器就立即复制合成图片。
- 后续添加标注、裁剪或修改背景不会更新剪贴板。
- 没有状态提示说明剪贴板仍是编辑前版本，用户容易粘贴出不符合预期的图片。
- 证据：`Sources/Rimva/App/AppController.swift:38-45`。

### 8. 取消截图会强行打开并聚焦编辑器

- 即使用户从其他应用通过全局快捷键截图，按 `Esc` 取消后也会执行 `showEditor()`。
- 用户不会返回之前的应用，而是被 Rimva 编辑器打断。
- 截图开始时设置窗口也会被隐藏，但取消后不会恢复设置窗口。
- 证据：`Sources/Rimva/App/AppController.swift:46`、`Sources/Rimva/App/AppController.swift:152-163`。

### 9. 长截图过程缺少有效进度和结果反馈

- 成功拼接一段与画面没有变化都会回到相同的“向下滚动，停稳后自动拼接”状态。
- 没有已拼接段数、本次新增高度、缩略预览或接缝检查。
- 用户只能观察总高度猜测拼接是否成功，最终进入编辑器后才能发现结果是否符合预期。
- 出错提示建议“重新框选”，但工具条没有对应操作，只能取消后重新开始。
- 证据：`Sources/Rimva/Capture/ScrollingCaptureSession.swift:115-127`、`Sources/Rimva/Capture/ScrollingCaptureSession.swift:257-294`。

### 10. 长截图的 `Esc` 取消路径不可靠

- 普通选区的键盘监听在进入长截图时已经移除。
- 长截图工具条只执行 `orderFrontRegardless`，没有主动成为 key window。
- `Esc` 依赖工具条自身的 `cancelOperation`，因此初始展示状态下没有可靠的接收路径。
- 证据：`Sources/Rimva/Capture/CaptureCoordinator.swift:187-197`、`Sources/Rimva/Capture/CaptureCoordinator.swift:212-220`、`Sources/Rimva/Capture/ScrollingCaptureSession.swift:212-227`、`Sources/Rimva/Capture/ScrollingCaptureSession.swift:297-303`。

### 11. 最终输出样式和尺寸不够明确

- 默认样式会添加 48 px 留白、圆角和阴影，复制和保存都使用合成后的图片。
- 编辑器没有显示输出尺寸、当前缩放比例或原始截图状态。
- 用户难以区分“原始区域截图”和“带默认背景的成图”，也无法在导出前确认最终像素尺寸。
- 证据：`Sources/RimvaCore/Models.swift:60-83`、`Sources/Rimva/App/AppController.swift:195-217`、`Sources/Rimva/Editor/CanvasView.swift:57-84`。

## P2：交互和 UI 不好用

### 12. 截图入口没有覆盖主要截图模式

- 截图入口只有“普通截图”和“长截屏”。
- 窗口截图和全屏截图没有出现在入口中。
- 后两者默认也没有全局快捷键，只能从菜单栏进入，降低发现效率。
- 证据：`Sources/Rimva/Capture/CaptureLauncher.swift:94-133`、`Sources/Rimva/App/HotKey.swift:82-99`。

### 13. 区域截图缺乏精确选择能力

- 没有局部放大镜、方向键微调、尺寸输入或常用比例。
- 选区只能依靠鼠标拖动和八个控制点调整。
- “取消/截图”按钮固定在屏幕底部中央，与选区脱离；选区离底部较远时操作路径很长。
- 证据：`Sources/Rimva/Capture/CaptureSelectionView.swift:60-64`、`Sources/Rimva/Capture/CaptureSelectionView.swift:104-159`、`Sources/Rimva/Capture/CaptureSelectionView.swift:162-239`。

### 14. 编辑画布缺少与操作匹配的光标和命中反馈

- 箭头、矩形、裁剪、移动和缩放没有对应的鼠标光标。
- 控制点视觉尺寸只有 6 px，且没有悬停反馈。
- 用户难以判断当前处于创建、移动还是缩放操作，也难以发现可拖动区域。
- 这里的问题是操作反馈不足，不是工具栏图标尺寸。
- 证据：`Sources/Rimva/Editor/CanvasView.swift:105-122`、`Sources/Rimva/Editor/CanvasView.swift:124-215`。

### 15. 撤销历史会被单纯选中标注污染

- 点击选中一个标注时，尚未发生任何修改就先创建撤销快照。
- 因此按一次撤销可能只是撤销一次选中操作，界面看起来没有实际变化。
- 单击但未拖动、创建过小标注后被自动移除等情况也可能留下无意义历史。
- 证据：`Sources/Rimva/Editor/CanvasView.swift:140-171`、`Sources/Rimva/Editor/CanvasView.swift:209-215`、`Sources/Rimva/Editor/EditorSession.swift:50-58`。

### 16. 保存流程不可控，保存结果不够可见

- 没有另存为、文件名选择或保存后直接显示文件的操作。
- 自动文件名包含时间和随机后缀，连续保存会生成多个相似文件。
- 成功提示只显示文件夹名，不显示实际文件名，也不能直接打开所在位置。
- 证据：`Sources/Rimva/Export/ImageExporter.swift:33-43`、`Sources/Rimva/App/AppController.swift:204-213`。

### 17. 背景面板遮住正在调整的图片

- 背景面板使用固定的 `440×540` popover，从顶部工具栏展开。
- 在默认 650 px 高的编辑窗口中，面板会覆盖大部分画布。
- 调整留白、阴影和背景时需要观察完整图片，当前布局会阻碍即时判断。
- 证据：`Sources/Rimva/Editor/EditorView.swift:86-89`、`Sources/Rimva/Editor/EditorView.swift:127-191`。

### 18. 部分图标和颜色控件语义不一致

- 序号使用“列表”图标，不能直观表达逐步编号。
- 遮挡仅使用普通实心矩形图标，与矩形工具的差异不够直观。
- 自定义颜色使用吸管图标，但实际行为是打开系统颜色面板，并非从屏幕取色。
- 遮挡工具仍显示颜色选择，但新建遮挡始终强制使用深色，当前颜色对下一块遮挡不起作用。
- 应保持工具栏紧凑，只修正语义和状态一致性。
- 证据：`Sources/Rimva/Editor/EditorSession.swift:5-10`、`Sources/Rimva/Editor/AnnotationToolbar.swift:24-50`、`Sources/Rimva/Editor/AnnotationToolbar.swift:165-190`、`Sources/Rimva/Editor/CanvasView.swift:164-171`。

## 验证说明

- 已运行演示编辑界面检查视觉布局。
- 已运行核心测试，41 项测试全部通过。
- 当前测试集中在图片合成、背景、拼接和本地化，不覆盖上述主要 UI 与交互问题。
