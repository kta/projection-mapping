import AVFoundation
import CoreImage

/// 動画/静止画ソースの抽象(F-SRC-1〜4)。OutputRendererが毎フレーム currentFrame() を呼ぶ。
protocol FrameSource: AnyObject {
    /// hostTime(CADisplayLinkのtargetTimestamp)に対応するフレーム。
    /// 新フレームがない場合はnil(レンダラは前フレームを再利用する)。
    func copyFrame(forHostTime hostTime: CFTimeInterval) -> CIImage?
}

/// TODO(TASK ENG-2 / 担当: engine agent):
/// AVPlayer + AVPlayerItemVideoOutput によるプル型動画ソース。
/// 実装要点(設計書§3.3・調査レポート§2の確定事項):
/// - AVPlayerItemVideoOutputのpixelBufferAttributesは
///   kCVPixelFormatType_420YpCbCr8BiPlanarFullRange を指定(YUVのままCIに渡す)。
/// - copyFrame: itemTime(forHostTime:) → hasNewPixelBuffer → copyPixelBuffer → CIImage。
/// - ループ再生(F-SRC-3)は AVPlayerLooper + AVQueuePlayer で実装(シームレス)。
/// - 再生/一時停止/シーク/音量(F-SRC-4)を公開する。
/// - 静止画は StillImageSource(下記)を使う。ロード失敗はthrowしUI側でアラート表示。
final class VideoSource: FrameSource {
    private(set) var player: AVQueuePlayer?

    init(url: URL, loop: Bool) {
        // TODO: ENG-2 — AVURLAsset読み込み、AVPlayerItemVideoOutput追加、AVPlayerLooper構成
    }

    func copyFrame(forHostTime hostTime: CFTimeInterval) -> CIImage? {
        nil // TODO: ENG-2
    }

    func play() { /* TODO: ENG-2 */ }
    func pause() { /* TODO: ENG-2 */ }
    func seek(to seconds: Double) { /* TODO: ENG-2 */ }
    var volume: Float {
        get { player?.volume ?? 0 }
        set { player?.volume = newValue }
    }
}

/// 静止画ソース(F-SRC-2): 常に同じCIImageを返すだけ。
final class StillImageSource: FrameSource {
    private let image: CIImage?

    init(url: URL) {
        self.image = CIImage(contentsOf: url)
    }

    func copyFrame(forHostTime hostTime: CFTimeInterval) -> CIImage? {
        image
    }
}
