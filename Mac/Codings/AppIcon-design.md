# 应用图标

2026-10-22 改为接近本机 ChatGPT 图标的黑白扁平风：不透明的近白色连续圆角底板，搭配两条石墨黑额度条。图标不使用玻璃、渐变、高光、投影或浮雕；液态玻璃仅用于应用详情页。

- 母图画布：1024 × 1024 RGBA；主体从 (100, 100) 到 (924, 924)，轮廓外透明，底板内部不透明。
- 底板 `#FCFCFB`，内侧细轮廓 `#E7E7E5`，额度槽 `#E3E3E1`，填充 `#171717`。
- 两条额度槽宽 560、高 112，填充分别约 75%／45%，对应 5 小时与 7 天额度窗口；不复制 ChatGPT 的结绳标志。
- `render-icon.swift` 是形状和配色的唯一来源，以同一组坐标输出 `AppIcon.svg` 和 `AppIcon.png`。
- `AppIcon.icns` 包含 16、32、128、256、512 点的 1x／2x 表示。当前 AppKit 应用使用静态 ICNS。

执行 `./Mac/Codings/build-icon.sh` 会先重新渲染母图与 SVG，再生成全部标准尺寸和 ICNS；执行 `./Mac/Codings/build-mac.sh` 将新图标复制到应用中并签名。仅需 Xcode Command Line Tools，不依赖 Icon Composer 或完整 Xcode。

设计参考为本机 ChatGPT 应用的白底／石墨黑配色，以及 [Apple 应用图标设计指引](https://developer.apple.com/design/human-interface-guidelines/app-icons/)。最终图标由原生矢量与 Core Graphics 精确绘制，保证扁平造型和干净透明边缘。
