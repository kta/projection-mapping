import UIKit

/// クロップガイドテンプレート書き出し(F-SRC-5)。
/// コンテンツ制作(AI生成・動画編集)の下絵として使う、各面の割り当て領域を
/// 色分けで示した1920×1080のPNGを生成する。
enum CropGuideExporter {

    static func pngData(preset: MappingPreset,
                        size: CGSize = CGSize(width: 1920, height: 1080)) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor.black.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // コーナー3面+自由面(F-FREE-1)を(名前, 色, crop)の共通形で描く
            var entries: [(name: String, color: UIColor, crop: CGRect)] =
                Surface.drawOrder.compactMap { s in
                    guard let crop = preset.surfaces[s]?.crop else { return nil }
                    return (s.displayName, identityColor(for: s), crop)
                }
            for e in preset.extras {
                entries.append((e.name, .green, e.config.crop))
            }

            for entry in entries {
                let crop = entry.crop
                let rect = CGRect(x: crop.minX * size.width,
                                  y: crop.minY * size.height,
                                  width: crop.width * size.width,
                                  height: crop.height * size.height)
                let color = entry.color

                color.withAlphaComponent(0.25).setFill()
                cg.fill(rect)

                color.setStroke()
                let border = UIBezierPath(rect: rect.insetBy(dx: 2, dy: 2))
                border.lineWidth = 4
                border.stroke()

                // 面名+正規化座標(制作ソフトでの位置合わせ用)
                let label = "\(entry.name)\n\(coordinateText(crop))" as NSString
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: min(48, rect.height * 0.15)),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph,
                ]
                let textSize = label.size(withAttributes: attrs)
                label.draw(in: CGRect(x: rect.midX - textSize.width / 2,
                                      y: rect.midY - textSize.height / 2,
                                      width: textSize.width,
                                      height: textSize.height),
                           withAttributes: attrs)
            }
        }
        return image.pngData()
    }

    private static func coordinateText(_ r: CGRect) -> String {
        String(format: "x:%.2f y:%.2f w:%.2f h:%.2f", r.minX, r.minY, r.width, r.height)
    }

    /// 定義は Surface.identityRGB(唯一の置き場)。
    private static func identityColor(for surface: Surface) -> UIColor {
        let rgb = surface.identityRGB
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
