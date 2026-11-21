-- Loading-screen tips. Keep this file as the single place to edit the bird
-- animation and the Chinese tips shown while Loenn starts up.

return {
    bird = {
        frameCount = 15,
        frameDuration = 0.12,
        scale = 2,
        margin = 24,
        -- Opaque pixel bounds inside the 32x24 bird frames. The sprite has transparent
        -- space above the bird, so layout uses these bounds instead of the image size.
        visualLeft = 8,
        visualTop = 11,
        visualRight = 23,
        visualBottom = 24,
    },

    settings = {
        duration = 6.5,
        fadeDuration = 0.35,
        maxWidth = 700,
        fontSize = 16,
        textGap = 8,
        rightMargin = 24,
    },

    tips = {
        "你知道吗？Loenn Ultra 已经支持中文，请在 Settings 里更改语言设置。",
        "你知道吗，在放置模式下用鼠标中键可以吸取实体。",
        "现在可以通过拖拽添加背景了！",
        "按住 Ctrl 可以临时进入精确放置模式。",
        "选中 decal 后按 R/L 可以旋转，按 H/V 可以翻转。部分实体也可以哦。",
        "滚轮可以缩放视图，右键拖拽可以平移视图。",
        "Tile 刷子工具的 Objects 图层可以放置 scenery 物件图块。",
        "撤销和重做会记录大部分编辑操作，不用担心手滑。",
        "在房间之间拖拽实体时，按住 Shift 可以保持对齐。",
        "双击项目，可以把它加入收藏。",
        "房间的宽度和高度可以在选中房间后直接调整。",
        "背景 decal 和前景 decal 分别位于 Decals 的两个图层中。",
        "在搜索框输入名称，可以快速筛选实体、触发器或砖块——甚至房间。",
        "按住 Shift 多选实体，可以一次移动或复制多个对象。",
        "右上角的图层按钮可以单独隐藏指定图层。",
        "按 Ctrl + Z 撤销，按 Ctrl + Shift + Z 重做。",
        "你可以通过按住 Ctrl 缩放房间使其大小小于一般最小值。",
        "在房间模式下，右键房间，选择编辑，可以打开房间编辑面板。",
        "你可以手动填写 decal 的旋转角度。",
        "按住 Shift 点击已选中的实体可以全选房间内的同类实体。",
        "在顶部选项栏点开帮助，点进下拉栏里的 Celeste Wiki，即可享用量大管饱的制图知识。",
        "你知道吗，右键可以拖动你的视图。",
        "侧向单向板的修正是默认关闭的，你需要自行开启。",
        "现在可以通过 Tile -> Bucket -> All Rooms 一键替换砖块了。",
        "在搜索栏中以 @ 开头可以按模组名搜索，以 ~ 开头可以模糊搜索。",
    },
}
