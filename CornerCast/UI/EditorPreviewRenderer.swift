import AVFoundation
import CoreImage
import UIKit

/// エディタキャンバスの背景プレビュー(F-OUT-4)。
/// 出力と**同じFrameComposer**を低解像度で回してUIImage化する — プレビューと
/// 実際の投影結果が必ず一致することを構造的に保証する(独自の描画経路を持たない)。
///
/// 呼び出しはMainActor・低解像度(既定640×360)・デバウンス前提。
/// 60fpsのリアルタイム描画用ではない(それはOutputRendererの仕事)。
@MainActor
final class EditorPreviewRenderer {
    static let shared = EditorPreviewRenderer()

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let composer = FrameComposer()
    private let testPattern = TestPatternGenerator()
    /// 動画のポスターフレーム(先頭フレーム)キャッシュ。URL単位。
    private var posterCache: [URL: CIImage] = [:]

    private init() {}

    /// 現在のプリセット+コンテンツからプレビュー画像を合成する。
    /// コンテンツ未選択・フレーム取得失敗時はnil(呼び出し側は黒背景のままにする)。
    func render(preset: MappingPreset,
                content: MappingViewModel.ContentSource,
                size: CGSize) -> UIImage? {
        switch content {
        case .none:
            return nil
        case .bakedVideo(let url):
            // ベイク済み動画は「合成済み」なので再ワープせず、そのまま縮小表示する
            guard let poster = posterFrame(for: url) else { return nil }
            return uiImage(from: scaled(poster, to: size), size: size)
        case .testPattern, .image, .video:
            let params = RenderParameters(canvasSize: size, preset: preset)
            guard let frame = sourceFrame(for: content, params: params) else { return nil }
            let composed = composer.compose(frame: frame, params: params)
            return uiImage(from: composed, size: size)
        }
    }

    // MARK: - ソースフレーム取得

    private func sourceFrame(for content: MappingViewModel.ContentSource,
                             params: RenderParameters) -> CIImage? {
        switch content {
        case .testPattern:
            testPattern.update(params: params)
            return testPattern.copyFrame(forHostTime: 0)
        case .image(let url):
            return CIImage(contentsOf: url)
        case .video(let url):
            return posterFrame(for: url)
        case .none, .bakedVideo:
            return nil
        }
    }

    /// 動画の先頭フレームを取得してキャッシュする(プレビューは静止でよい)。
    private func posterFrame(for url: URL) -> CIImage? {
        if let cached = posterCache[url] { return cached }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        let image = CIImage(cgImage: cg)
        posterCache[url] = image
        return image
    }

    // MARK: - 変換ヘルパ

    private func scaled(_ image: CIImage, to size: CGSize) -> CIImage {
        let sx = size.width / max(image.extent.width, 1)
        let sy = size.height / max(image.extent.height, 1)
        return image
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private func uiImage(from image: CIImage, size: CGSize) -> UIImage? {
        guard let cg = context.createCGImage(image, from: CGRect(origin: .zero, size: size)) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
