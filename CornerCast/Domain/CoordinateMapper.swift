import CoreGraphics

/// 座標系変換の唯一の置き場(Models.swift冒頭の規約参照)。
/// ここ以外で `1 - y` のようなY反転を書いたらレビューで差し戻すこと。
enum CoordinateMapper {

    // MARK: UI座標 <-> 正規化座標

    /// SwiftUIビュー内のローカル座標(pt) -> 正規化座標
    static func normalized(fromUI p: CGPoint, in viewSize: CGSize) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        return CGPoint(x: p.x / viewSize.width, y: p.y / viewSize.height)
    }

    /// 正規化座標 -> SwiftUIビュー内のローカル座標(pt)
    static func ui(fromNormalized p: CGPoint, in viewSize: CGSize) -> CGPoint {
        CGPoint(x: p.x * viewSize.width, y: p.y * viewSize.height)
    }

    // MARK: 正規化座標 -> CIピクセル座標(Y反転はここだけ)

    /// 正規化座標(左上原点) -> Core Imageピクセル座標(左下原点)
    static func ciPixel(fromNormalized p: CGPoint, canvasSize: CGSize) -> CGPoint {
        CGPoint(x: p.x * canvasSize.width, y: (1 - p.y) * canvasSize.height)
    }

    /// 正規化矩形(左上原点) -> ソース画像extent内のCIピクセル矩形(左下原点)。
    /// 正規化rectの「上端」はCIでは extent.maxY 側になる。
    static func ciRect(fromNormalized r: CGRect, in extent: CGRect) -> CGRect {
        let x = extent.origin.x + r.origin.x * extent.width
        let w = r.width * extent.width
        let h = r.height * extent.height
        // 左上原点の r.origin.y は「上からの距離」。CIの下端yは上端から高さを引いた位置。
        let topY = extent.origin.y + (1 - r.origin.y) * extent.height
        let y = topY - h
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
