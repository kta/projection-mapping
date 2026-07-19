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

        // 0) 出力エフェクト(F-FX-1): 分割前にソース全体へ適用(全面で色調が揃う)
        let source = params.effects.isNeutral ? frame : applyEffects(frame, params.effects)

        for s in params.surfaces {   // コーナー3面(drawOrder順)→自由面
            let piece = warpedPiece(frame: source, surface: s, canvasSize: params.canvasSize)
            canvas = piece.composited(over: canvas)
        }

        // 4) 出力マスク(F-MASK-1): 最後に黒四角形を重ねて遮光する
        for quad in params.maskQuads {
            canvas = blackQuad(quad, canvasSize: params.canvasSize).composited(over: canvas)
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

        // 2.5) エッジフェザリング(F-WARP-7): 境界を柔らかくして継ぎ目を目立ちにくくする
        if s.feather > 0 {
            image = feathered(image, amount: s.feather)
        }

        // 3) 射影変換。メッシュワープ(F-MESH-1)有効時はセル分割してセル単位のホモグラフィ、
        //    無効時は従来の4点ホモグラフィ1発。
        if let mesh = s.mesh, mesh.rows >= 2, mesh.cols >= 2,
           mesh.points.count == mesh.rows * mesh.cols {
            return meshWarped(image, mesh: mesh, canvasSize: canvasSize)
        }
        return singleWarp(image, quad: s.quad, canvasSize: canvasSize)
    }

    /// 4点ホモモグラフィ1発の従来ワープ。
    /// CIPerspectiveTransformは数学的に正しいホモグラフィ補間を行う(三角形分割の折れが出ない)。
    private func singleWarp(_ image: CIImage, quad: Quad, canvasSize: CGSize) -> CIImage {
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = image
        warp.topLeft = CoordinateMapper.ciPixel(fromNormalized: quad.topLeft, canvasSize: canvasSize)
        warp.topRight = CoordinateMapper.ciPixel(fromNormalized: quad.topRight, canvasSize: canvasSize)
        warp.bottomRight = CoordinateMapper.ciPixel(fromNormalized: quad.bottomRight, canvasSize: canvasSize)
        warp.bottomLeft = CoordinateMapper.ciPixel(fromNormalized: quad.bottomLeft, canvasSize: canvasSize)
        return warp.outputImage ?? image
    }

    /// メッシュワープ(F-MESH-1): ソース片を(rows-1)×(cols-1)セルへ軸平行分割し、
    /// 各セルを対応する制御点quadへホモグラフィ変換して合成する。
    /// 隣接セルは制御点(エッジ)を共有するため、境界は連続する(区分的射影変換)。
    /// フェザーは分割前に適用済みなので、セル境界に切れ目は出ない。
    private func meshWarped(_ image: CIImage, mesh: WarpMesh, canvasSize: CGSize) -> CIImage {
        let extent = image.extent
        var acc = CIImage.empty()
        for r in 0..<(mesh.rows - 1) {
            for c in 0..<(mesh.cols - 1) {
                let u0 = CGFloat(c) / CGFloat(mesh.cols - 1)
                let u1 = CGFloat(c + 1) / CGFloat(mesh.cols - 1)
                let v0 = CGFloat(r) / CGFloat(mesh.rows - 1)
                let v1 = CGFloat(r + 1) / CGFloat(mesh.rows - 1)
                // 正規化セル(左上原点) → ソース片extent内のCI矩形 → 原点へ平行移動
                let srcRect = CoordinateMapper.ciRect(
                    fromNormalized: CGRect(x: u0, y: v0, width: u1 - u0, height: v1 - v0),
                    in: extent)
                let cell = image.cropped(to: srcRect)
                    .transformed(by: CGAffineTransform(translationX: -srcRect.minX,
                                                       y: -srcRect.minY))
                let warp = CIFilter.perspectiveTransform()
                warp.inputImage = cell
                warp.topLeft = CoordinateMapper.ciPixel(
                    fromNormalized: mesh.point(row: r, col: c), canvasSize: canvasSize)
                warp.topRight = CoordinateMapper.ciPixel(
                    fromNormalized: mesh.point(row: r, col: c + 1), canvasSize: canvasSize)
                warp.bottomRight = CoordinateMapper.ciPixel(
                    fromNormalized: mesh.point(row: r + 1, col: c + 1), canvasSize: canvasSize)
                warp.bottomLeft = CoordinateMapper.ciPixel(
                    fromNormalized: mesh.point(row: r + 1, col: c), canvasSize: canvasSize)
                if let out = warp.outputImage {
                    acc = out.composited(over: acc)
                }
            }
        }
        return acc
    }

    /// 出力マスク(F-MASK-1): 黒い矩形を指定quadへワープしたもの
    private func blackQuad(_ quad: Quad, canvasSize: CGSize) -> CIImage {
        let base = CIImage(color: .black)
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        return singleWarp(base, quad: quad, canvasSize: canvasSize)
    }

    /// 出力エフェクト(F-FX-1): 彩度/コントラスト/明度(CIColorControls)+色相(CIHueAdjust)
    private func applyEffects(_ image: CIImage, _ fx: EffectSettings) -> CIImage {
        var out = image
        if fx.saturation != 1.0 || fx.contrast != 1.0 || fx.brightness != 0.0 {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.saturation = Float(fx.saturation)
            f.contrast = Float(fx.contrast)
            f.brightness = Float(fx.brightness)
            out = f.outputImage ?? out
        }
        if fx.hueDegrees != 0.0 {
            let f = CIFilter.hueAdjust()
            f.inputImage = out
            f.angle = Float(fx.hueDegrees * .pi / 180)
            out = f.outputImage ?? out
        }
        return out
    }

    /// エッジフェザリング: 内側にinsetした白矩形をぼかしたものをアルファマスクとして適用する。
    /// amountは短辺に対する割合(0-0.3)。ワープ前に適用するため、境界のぼけも一緒に変形される。
    private func feathered(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        let inset = min(extent.width, extent.height) * CGFloat(amount) * 0.5
        guard inset > 0.5 else { return image }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = CIImage(color: .white).cropped(to: extent.insetBy(dx: inset, dy: inset))
        blur.radius = Float(inset / 2)
        let mask = (blur.outputImage ?? CIImage(color: .white)).cropped(to: extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: extent)
    }
}
