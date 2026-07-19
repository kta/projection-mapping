import CoreImage
import UIKit

/// テストパターン(F-UI-2): キャリブレーション時に投影する、面ごとに色分けされたグリッド。
/// FrameComposerへの入力(ソースフレーム相当)として使うため、
/// 「超広角ソース動画と同じ形」= 各面のcrop領域にそれぞれの面のパターンが入った1枚 を生成する。
///
/// 生成した1920x1080のCIImageはFrameComposerが通常の動画フレームと同じ経路で
/// crop → warp する。したがってここでは quad を一切適用せず、crop領域に素の
/// パターンを描くだけでよい(warpはFrameComposer側の責務)。
final class TestPatternGenerator: FrameSource {
    private var cached: CIImage?
    private var cacheKey: String?

    /// レンダラから毎フレーム呼ばれる。paramsはupdate(params:)で事前に渡す。
    private var params: RenderParameters?
    private let sourceSize = CGSize(width: 1920, height: 1080)

    func update(params: RenderParameters) {
        self.params = params
    }

    func copyFrame(forHostTime hostTime: CFTimeInterval) -> CIImage? {
        guard let params else { return nil }
        // crop構成が変わらない限り再描画しない(quadの変化ではキャッシュを無効化しない)
        let key = Self.cacheKey(for: params, sourceSize: sourceSize)
        if key == cacheKey, let cached {
            return cached
        }
        let image = renderPattern(params: params)
        cached = image
        cacheKey = key
        return image
    }

    // MARK: - 描画

    /// 1920x1080に一度だけ描画してCIImage化する。
    /// UIKit(左上原点)で描いたCGImageを CIImage(cgImage:) に渡すと視覚的な上下は保たれ、
    /// 正規化crop(左上原点)と CoordinateMapper.ciRect の対応がそのまま成立する。
    private func renderPattern(params: RenderParameters) -> CIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // 1pt=1pxに固定(1920x1080ピクセルを厳密に得る)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: sourceSize, format: format)

        let uiImage = renderer.image { context in
            let cg = context.cgContext
            // crop領域外は黒
            UIColor.black.setFill()
            cg.fill(CGRect(origin: .zero, size: sourceSize))
            for s in params.surfaces {
                drawSurface(s, in: cg)
            }
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// 1面ぶんのパターン: 外周枠 + 10x10グリッド + 対角線 + 面ラベル。
    private func drawSurface(_ s: RenderParameters.SurfaceRender, in cg: CGContext) {
        // 正規化crop(左上原点) → ソースピクセル矩形(左上原点)
        let rect = CGRect(
            x: s.crop.origin.x * sourceSize.width,
            y: s.crop.origin.y * sourceSize.height,
            width: s.crop.width * sourceSize.width,
            height: s.crop.height * sourceSize.height
        )
        guard rect.width > 1, rect.height > 1 else { return }

        let color = Self.identityColor(for: s.surface)

        // 10x10グリッド(境界を含む11本ずつ)
        let cells = 10
        let grid = UIBezierPath()
        for i in 0...cells {
            let t = CGFloat(i) / CGFloat(cells)
            let x = rect.minX + rect.width * t
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * t
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        color.withAlphaComponent(0.55).setStroke()
        grid.lineWidth = 1
        grid.stroke()

        // 対角線(向き確認用)
        let diagonals = UIBezierPath()
        diagonals.move(to: CGPoint(x: rect.minX, y: rect.minY))
        diagonals.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        diagonals.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        diagonals.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        color.withAlphaComponent(0.8).setStroke()
        diagonals.lineWidth = 2
        diagonals.stroke()

        // 外周枠(内側にオフセットして矩形内に収める)
        let borderWidth: CGFloat = 6
        let border = UIBezierPath(rect: rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))
        color.setStroke()
        border.lineWidth = borderWidth
        border.stroke()

        // 面ラベル(中央)
        let text = s.surface.displayName as NSString
        let fontSize = max(24, min(rect.width, rect.height) * 0.22)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: color,
        ]
        let textSize = text.size(withAttributes: attributes)
        let origin = CGPoint(x: rect.midX - textSize.width / 2,
                             y: rect.midY - textSize.height / 2)
        text.draw(at: origin, withAttributes: attributes)
    }

    /// 面ごとの識別色(左壁=シアン / 正面壁=マゼンタ / 床=イエロー)
    private static func identityColor(for surface: Surface) -> UIColor {
        switch surface {
        case .leftWall: .cyan
        case .frontWall: .magenta
        case .floor: .yellow
        }
    }

    /// crop矩形群からキャッシュキーを作る(quadは含めない)
    private static func cacheKey(for params: RenderParameters, sourceSize: CGSize) -> String {
        var parts: [String] = [String(format: "%.0fx%.0f", sourceSize.width, sourceSize.height)]
        for s in params.surfaces {
            parts.append(String(format: "%@:%.5f,%.5f,%.5f,%.5f",
                                s.surface.rawValue,
                                s.crop.origin.x, s.crop.origin.y,
                                s.crop.width, s.crop.height))
        }
        return parts.joined(separator: "|")
    }
}
