# 应用图标

蓝色连续圆角底板搭配两条白色玻璃额度条，分别对应 5 小时和 7 天额度窗口。新图标沿用详情界面的蓝色，采用简洁的大形状与轻微层次，让 32／64 像素下仍能分辨双条结构；16 像素下保留蓝底与双横条轮廓。

- `AppIcon.png`：1024 × 1024 RGBA 母图，外围透明。
- `AppIcon.icns`：使用 Apple `iconutil` 封装，包含 16、32、128、256、512 点的 1x 和 2x 表示。
- 重建命令：`./Mac/Codings/build-icon.sh`。应用打包脚本 `./Mac/Codings/build-mac.sh` 会复制 ICNS 到应用资源目录。
- 这是兼容现有 AppKit 应用的静态 ICNS，不是 Icon Composer 的动态分层图标。

2026-10-21 使用内置 `image_gen` 重新生成并精修画面，保留工具提供的真实 Alpha 通道，通过系统 `sips` 缩放为 1024 像素母图。ICNS 解包核对了全部 10 个尺寸、Alpha 和四角透明度。此图标采用静态玻璃质感，未宣称拥有 Icon Composer 的动态光照或外观切换。

设计参考：[Apple App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons/)。

初始生成提示词：

Use case: logo-brand. Asset type: one final production macOS 27 application icon for a personal quota dashboard with two quota windows (5 hours and 7 days). Create an entirely new design, not a mockup. Single square 1024x1024 composition with true alpha transparency outside the icon. Centered macOS continuous-curvature rounded-square tile, occupying 82 percent of canvas width, equal margins, orthographic front view. Blue is the app's established interface color. Tile is a refined vivid system-blue glass surface, gently deeper blue toward its lower edge, with very restrained light catching its upper edge, subtle dimensional layering. Main symbol: exactly TWO bold horizontal rounded capsule quota meters, stacked with generous vertical spacing and equal overall width. Each is a luminous translucent milky-white glass track with a bright opaque white remaining-portion inside it: upper meter approximately 75 percent full, lower meter approximately 45 percent full. The filled and unfilled parts must be immediately distinct and simple enough to read at 32px, using a single white family, no outlines or little details. Both meters float just above the blue tile with very subtle soft shadows, clean precision geometry and balanced negative space. Beautiful native Apple desktop utility aesthetic, confident simple shapes, finely restrained Liquid Glass depth; no heavy bevels or toy-like plastic. All artwork and soft shadow fit fully within the canvas. No text, no letters, no numbers, no percentages, no needle, no circular gauge, no purple, no logos, no knots, no badges, no decorative sparkles, no other objects, no presentation sheet, no border frame, no watermark, no checkerboard background. Deliver only the single isolated icon, ready for use as the app icon.

边缘精修提示词：

Use case: background-extraction. Edit target: the attached blue macOS app icon with two white quota meter bars. Preserve the design, blue color, two meter positions and fill lengths, overall geometry, composition and transparent outer margins. Refine only its finish and alpha edges for production: remove every cyan/white speck, streak, colored fringe, glow noise or stray pixel outside the rounded-square tile. The exterior must be truly transparent, perfectly clean; a very small smooth neutral soft shadow is acceptable. Clean anti-aliased continuous-curvature silhouette with no rough edges. Reduce overly strong specular rim highlights slightly so the glass finish is restrained and feels like a polished macOS 27 native application icon. Do not add text, objects, colors, logos, a background or a checkerboard. Return the same single isolated icon on genuine transparency, 1024x1024 square.

最终精修提示词：

Edit target: this blue rounded-square application icon with exactly two white quota bars. Keep the basic design and layout exactly. Make one final polish pass to create a QUIETER, more precise native macOS 27 icon: eliminate the bright cyan glowing outer rim entirely, remove the multiple concentric outline/bevel edges, remove every speck and all outer glow. Replace the perimeter with ONE clean smooth blue silhouette with a soft single subtle highlight INSIDE the tile, no halo or decorative outer stroke. Flatten the tile's depth slightly and lower the highlights by about one third. Keep the two white glass meters, same sizes, same vertical positions, same 75/45 fill percentages, and preserve their contrast. The transparent outside must contain absolutely no scattered blue/cyan pixels, only an optional extremely faint neutral soft shadow beneath the tile. Balanced equal transparent margins. True RGBA alpha, 1024 square. No other changes, no text, no letters, no numbers, no backgrounds. Only the final isolated icon.
