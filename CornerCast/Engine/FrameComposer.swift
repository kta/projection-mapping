import CoreImage
import CoreImage.CIFilterBuiltins

/// コア合成アルゴリズム: 1フレーム(CIImage)を crop×3 → 色補正 → warp×3 → 黒背景に合成。
/// リアルタイムモード(OutputRenderer)とベイク(BakeExporter)の両方がこの同一実装を使う。
/// **純関数**であること: 状態を持たず、同じ入力に対して常に同じレシピを返す。
/// CIImageのフィルタチェーン構築は遅延評価で軽量なため、毎フレーム呼んでよい。
struct FrameComposer: Sendable {

    /// - Parameters:
    ///   - frame: ソース動画/画像の1フレーム(extentは任意。原点0でなくてもよい)
    ///   - params: 12点・クロップ・色補正・キャンバスサイズのスナップショット
    /// - Returns: extentが (0,0,canvasSize) の合成済みイメージ
    func compose(frame: CIImage, params: RenderParameters) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: params.canvasSize)
        var canvas = CIImage(color: .black).cropped(to: canvasRect)

        for s in params.surfaces {   // Surface.drawOrder順(床→左壁→正面壁)
            let piece = warpedPiece(frame: frame, surface: s, canvasSize: params.canvasSize)
            canvas = piece.composited(over: canvas)
        }
        // 合成結果がキャンバス外へはみ出さないよう最終クロップ
        return canvas.cropped(to: canvasRect)
    }

    /// 1面ぶん: crop → 色補正 → 射影変換
    private func warpedPiece(frame: CIImage, surface s: RenderParameters.SurfaceRender,
                             canvasSize: CGSize) -> CIImage {
        // 1) クロップ(正規化矩形 → ソースextent内のCI矩形)。
        //    その後extentを原点(0,0)へ平行移動する — CIPerspectiveTransformの写像は
        //    入力extent基準のため、原点始まりに正規化しておくと挙動が一意になる。
        let cropRect = CoordinateMapper.ciRect(fromNormalized: s.crop, in: frame.extent)
        var image = frame.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        // 2) 色補正(F-WARP-6)。無補正時はフィルタ自体を挟まない
        if s.brightness != 1.0 {
            let gain = CIFilter.colorMatrix()
            gain.inputImage = image
            let g = CGFloat(s.brightness)
            gain.rVector = CIVector(x: g, y: 0, z: 0, w: 0)
            gain.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            gain.bVector = CIVector(x: 0, y: 0, z: g, w: 0)
            image = gain.outputImage ?? image
        }
        if s.gamma != 1.0 {
            let gamma = CIFilter.gammaAdjust()
            gamma.inputImage = image
            gamma.power = Float(s.gamma)
            image = gamma.outputImage ?? image
        }

        // 3) 射影変換: 入力extentの4隅を、キャンバス上の指定4点(CIピクセル座標)へ写す。
        //    CIPerspectiveTransformは数学的に正しいホモグラフィ補間を行う(三角形分割の折れが出ない)。
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = image
        warp.topLeft = CoordinateMapper.ciPixel(fromNormalized: s.quad.topLeft, canvasSize: canvasSize)
        warp.topRight = CoordinateMapper.ciPixel(fromNormalized: s.quad.topRight, canvasSize: canvasSize)
        warp.bottomRight = CoordinateMapper.ciPixel(fromNormalized: s.quad.bottomRight, canvasSize: canvasSize)
        warp.bottomLeft = CoordinateMapper.ciPixel(fromNormalized: s.quad.bottomLeft, canvasSize: canvasSize)
        return warp.outputImage ?? image
    }
}
