import AVFoundation
import CoreImage
import os

/// 動画/静止画ソースの抽象(F-SRC-1〜4)。OutputRendererが毎フレーム currentFrame() を呼ぶ。
protocol FrameSource: AnyObject {
    /// hostTime(CADisplayLinkのtargetTimestamp)に対応するフレーム。
    /// 新フレームがない場合はnil(レンダラは前フレームを再利用する)。
    func copyFrame(forHostTime hostTime: CFTimeInterval) -> CIImage?
}

/// AVQueuePlayer + AVPlayerLooper + AVPlayerItemVideoOutput によるプル型動画ソース。
/// 設計書§3.3・調査レポート§2の確定事項に沿う。
///
/// ループ実装の要点(重要): AVPlayerLooper はテンプレートitemの「コピー」を
/// キューへ流し込む。したがってvideoOutputをテンプレートitemに付けても、実際に
/// 再生されるコピーitemからはピクセルバッファを取得できない。そこで
/// player.currentItem をKVO監視し、現在再生中のitemへvideoOutputを付け替える。
final class VideoSource: FrameSource {
    private(set) var player: AVQueuePlayer?

    private let templateItem: AVPlayerItem
    private var looper: AVPlayerLooper?
    private var currentItemObservation: NSKeyValueObservation?

    /// 現在再生中のitemに紐づくvideoOutput。copyFrameはこれを読む。
    private var videoOutput: AVPlayerItemVideoOutput?
    /// videoOutputを付与済みのitem(付け替え判定用)
    private weak var outputItem: AVPlayerItem?

    /// YUV(420f)のままCore Imageへ渡し、RGBA変換コストを避ける(Apple公式ガイド)
    private static let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String:
            Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    ]

    /// 向き補正(F-SRC-1)。iPhoneの縦撮り等は preferredTransform に回転が入っており、
    /// これを適用しないと実出力だけが横倒しになる。プレビュー側は
    /// AVAssetImageGenerator.appliesPreferredTrackTransform で既に補正済みなので、
    /// ここを入れないとプレビューと投影で向きが食い違う。
    /// 非同期で読み込むため、確定するまでは identity(無補正)。
    /// self を跨がずロック(Sendable)だけをTaskへ渡し、スレッド越しの共有を安全にする。
    private let orientation = OSAllocatedUnfairLock<CGAffineTransform>(initialState: .identity)

    init(url: URL, loop: Bool) {
        let asset = AVURLAsset(url: url)
        templateItem = AVPlayerItem(asset: asset)
        let queuePlayer = AVQueuePlayer()
        player = queuePlayer

        // preferredTransform の読み込みはI/Oを伴うので非同期で行う(再生開始はブロックしない)
        let orientation = self.orientation
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let transform = try? await track.load(.preferredTransform) else { return }
            orientation.withLock { $0 = transform }
        }

        // currentItemが差し替わるたび、そのitemへvideoOutputを付け替える
        currentItemObservation = queuePlayer.observe(\.currentItem, options: [.initial, .new]) {
            [weak self] player, _ in
            self?.attachOutputIfNeeded(to: player.currentItem)
        }

        if loop {
            // AVPlayerLooperがテンプレートのコピーをキューへ供給する(シームレスループ)
            looper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)
        } else {
            queuePlayer.insert(templateItem, after: nil)
        }
    }

    /// 現在再生中のitemにまだvideoOutputが付いていなければ、新規に生成して付与する。
    private func attachOutputIfNeeded(to item: AVPlayerItem?) {
        guard let item, item !== outputItem else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: Self.pixelBufferAttributes)
        item.add(output)
        videoOutput = output
        outputItem = item
    }

    func copyFrame(forHostTime hostTime: CFTimeInterval) -> CIImage? {
        guard let output = videoOutput else { return nil }
        let itemTime = output.itemTime(forHostTime: hostTime)
        // 新フレームがある時だけ取り出す(hostTime基準)。無ければnil→前フレーム再利用。
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime,
                                                       itemTimeForDisplay: nil) else {
            return nil
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return Self.applyingOrientation(orientation.withLock { $0 }, to: image)
    }

    /// preferredTransform を CIImage へ適用し、原点を (0,0) へ戻す。
    /// CIImage は左下原点なので、回転後に extent.origin が負になる。そのまま合成へ渡すと
    /// CoordinateMapper.ciRect が想定する「extent基準の正規化」がずれるため、必ず正規化する。
    static func applyingOrientation(_ transform: CGAffineTransform, to image: CIImage) -> CIImage {
        guard !transform.isIdentity else { return image }
        let rotated = image.transformed(by: transform)
        let e = rotated.extent
        guard e.origin != .zero else { return rotated }
        return rotated.transformed(by: CGAffineTransform(translationX: -e.origin.x,
                                                         y: -e.origin.y))
    }

    func play() { player?.play() }

    func pause() { player?.pause() }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

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
