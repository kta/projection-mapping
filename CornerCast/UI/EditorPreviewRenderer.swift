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

    /// 動画のポスターフレーム(先頭フレーム)キャッシュ。
    ///
    /// **NSCache であること。** 値は非圧縮ビットマップ(1080pで約8MB、4Kで約33MB)で、
    /// 取り込みのたびにUUID名の新しいtmpへコピーされるためキーは毎回変わる。
    /// 素の Dictionary だとエビクションも memory-warning 応答も無く、
    /// 候補の動画を数本見比べただけで数百MBが常駐したままになる。
    private let posterCache: NSCache<NSURL, PosterEntry> = {
        let cache = NSCache<NSURL, PosterEntry>()
        cache.countLimit = 8
        return cache
    }()

    /// NSCache は AnyObject しか保持できないので CIImage を包む
    final class PosterEntry {
        let image: CIImage
        init(_ image: CIImage) { self.image = image }
    }

    /// 直近に取得できたライブフレーム(1枚だけ保持)。コンテンツ切替時に破棄する。
    private var lastLiveFrame: CIImage?
    private var lastLiveKey: String?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [posterCache] _ in
            posterCache.removeAllObjects()
        }
    }

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
            // コンテンツが変わったら保持しているライブフレームを捨てる(前の動画が残らないように)
            let key = String(describing: content)
            if key != lastLiveKey {
                lastLiveKey = key
                lastLiveFrame = nil
            }
            let params = RenderParameters(canvasSize: size, preset: preset)
            guard let frame = sourceFrame(for: content, params: params) else { return nil }
            let composed = composer.compose(frame: frame, params: params)
            return uiImage(from: composed, size: size)
        }
    }

    /// クロップ編集(F-CROP-2)用: ワープを掛けない「ソース映像そのもの」のプレビュー。
    /// テストパターンはクロップ構成に依存して描かれる(循環する)ため対象外とし、
    /// 呼び出し側はグリッド背景へフォールバックする。
    func sourcePreview(content: MappingViewModel.ContentSource, size: CGSize) -> UIImage? {
        switch content {
        case .image(let url):
            guard let ci = CIImage(contentsOf: url) else { return nil }
            return uiImage(from: scaled(ci, to: size), size: size)
        case .video(let url), .bakedVideo(let url):
            guard let poster = posterFrame(for: url) else { return nil }
            return uiImage(from: scaled(poster, to: size), size: size)
        case .none, .testPattern:
            return nil
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
            // 再生中なら**そのフレーム**を使う。プロジェクター未接続でも
            // 手元のプレビューが実際に動くようにするため(以前は先頭フレームの静止画だけだった)。
            //
            // 新フレームが無いtickでは直近のライブフレームを再利用する。
            // 外部ディスプレイ接続中は OutputRenderer と同じ AVPlayerItemVideoOutput を
            // 引くため取りこぼしが起きるが、ポスターへ戻すとちらつくので保持した方を使う。
            if let live = AppServices.shared.playback.realtimeSource?
                .copyFrame(forHostTime: CACurrentMediaTime()) {
                lastLiveFrame = live
                return live
            }
            if let last = lastLiveFrame { return last }
            return posterFrame(for: url)
        case .none, .bakedVideo:
            return nil
        }
    }

    /// 動画の先頭フレーム。再生中のライブフレームが取れないときのフォールバック。
    private func posterFrame(for url: URL) -> CIImage? {
        if let cached = posterCache.object(forKey: url as NSURL) { return cached.image }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // フルサイズのビットマップを持たない。プレビューは高々640×360で足りる。
        generator.maximumSize = CGSize(width: 960, height: 540)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        let image = CIImage(cgImage: cg)
        posterCache.setObject(PosterEntry(image), forKey: url as NSURL)
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
