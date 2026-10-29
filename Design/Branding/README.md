# Airport Monitor · 猫头鹰 06

2026-10-18 选定的 [owl-06-flat-v2.svg](owl-06-flat-v2.svg) 是应用与菜单栏图标的造型来源：保留不对称耳簇、侧看眼睛、矮胖轮廓和左侧翅膀。

## 资源

- [应用图标](../../Sources/App/Assets.xcassets/AppIcon.appiconset/app-512@2x.png)：白色圆角底座、黑色猫头鹰、白眼和橙红嘴，无渐变、纹理或阴影。
- [菜单栏图形](MenuBarSymbol.svg)：相同轮廓的单色模板，眼睛和嘴部镂空，由系统适配浅深色。
- 应用图标和菜单栏资源分别位于 `Assets.xcassets/AppIcon.appiconset` 与 `MenuBarIcon.imageset`。

## 状态栏反馈

正常猫头鹰在左键按下时纵向压缩约 9–12%、横向扩张约 4–5%，底部固定；松开后回弹并随机眨眼 1–3 次。身体先响应，头部延后 40–70 ms 跟随。移出按钮后松开、面板关闭和内容切换会复位，播放期间及 800 ms 内不重复触发。右键、键盘／程序打开、仅余额和异常状态不播放；系统开启「减少动态效果」时保持静态。

异常状态使用珊瑚红双叉眼、伸舌头猫头鹰：浅色 `#CF5149`，深色 `#FF8A80`。异常条件沿用既有 `needsAttention`，具体原因由面板文字说明；余额文字仍使用系统颜色。

静态与动态轮廓共用 `Sources/App/MenuBar/OwlLogoGeometry.swift` 的矢量路径，`OwlTouchResponse` 和 `StatusLogoFeedback` 负责动效。更新原稿后需同步路径，并运行 `tools/status-bar/verify-vector.swift` 验证随机响应边界。

## 重新导出

依次运行 `swift Design/Branding/render-owl.swift` 和 `python3 Design/Branding/build-owl-assets.py`；后者需要 Pillow。`render-symbol.swift` 可单独导出菜单栏源文件。
