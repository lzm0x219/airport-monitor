# Airport Monitor · 猫头鹰 06

用户于 2026-10-18 选定 `owl-06-flat-v2.svg`，并要求替换应用及菜单栏图标。该稿直接描摹选定的 06，保留不对称耳簇、侧看眼睛、矮胖轮廓与左侧翅膀。

- 应用图标最大尺寸为 [app-512@2x.png](../../Sources/App/Assets.xcassets/AppIcon.appiconset/app-512@2x.png)：白色圆角底座，纯黑猫头鹰、白眼及橙红嘴；没有渐变、纹理或阴影。
- MenuBarSymbol.svg：同一猫头鹰轮廓的单色适配，眼睛及嘴部镂空。导出 18px / 36px 资源，系统通过模板图自动着色。
- 应用图标通过 Assets.xcassets/AppIcon.appiconset 提供完整 Mac 尺寸。
- 菜单栏通过 MenuBarIcon.imageset 加载 18pt 黑白模板图，由系统随深浅外观着色。

重新导出：先运行 `swift Design/Branding/render-owl.swift`，再运行 `python3 Design/Branding/build-owl-assets.py`（需要 Pillow）。原始选定 SVG 是唯一造型来源，菜单栏不重新设计轮廓。`render-symbol.swift` 仍可独立导出菜单栏源文件。

异常状态使用用户选定的v5珊瑚红双叉眼＋伸舌头猫头鹰，由`OwlLogoGeometry.dizzyImage`直接绘制，沿用原轮廓。浅色#CF5149、深色#FF8A80；奶白圆眼窝内为圆端双叉眼，下方为上扬嘴口与浅粉长圆舌尖及细描边，余额文字沿用系统颜色。正常状态仍使用黑白模板图；异常表情不播放正常眼睛的点击动效。异常触发条件沿用原有needsAttention（包括同步错误、低余量、到期等），不改变风险计算。订阅标识、钥匙串服务、用户偏好和历史存储路径保持原样。

菜单栏静态与点击动效使用 `Sources/App/OwlLogoGeometry.swift` 中从 `owl-06-flat-v2.svg` 原样复制的三次曲线路径。身体／翅膀与头部沿曲线分层，在颈部少量重叠以避免旋转裂缝；静止并集沿用原轮廓。眼部镂空与嘴部随头部运动，瞳孔不单独形变；上下曲线眼睑在固定眼部蒙版内遮合，蒙版外扩0.12pt消除抗锯齿残线。`OwlTouchResponse` 每次点击选定有界随机的推力、方向、幅度、阻尼、头部延迟与多次眨眼参数；身体、头部和眼睑共用采样时钟但错开起动，后续眨眼间隔不固定，不再按三种动作轮换。`StatusLogoFeedback` 负责播放，初始化禁用隐式动画。菜单栏静态图同样使用这组矢量，避免播放前后切换绘制方式。更新原稿时需同步路径并运行 `tools/status-bar/verify-vector.swift`；该工具用固定种子验证随机响应边界，并生成三个随机样例的GIF预览（非原生屏幕录制）；正式点击使用系统随机源。原工具栏和应用图标仍使用既有资源。早期闭眼位图及生成脚本已被此实现替换。

