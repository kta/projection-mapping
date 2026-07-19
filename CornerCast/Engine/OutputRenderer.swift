import CoreImage
import Metal
import QuartzCore
import UIKit

/// リアルタイムモードのレンダラ(F-RT-1): CADisplayLink駆動で
/// FrameSource → FrameComposer → CAMetalLayer に毎フレーム描画する。
/// 設計書§3.3・§5、調査レポート§2の確定事項に沿う。
/// NSObject継承はCADisplayLinkのselectorターゲット(@objcメソッド)に必要。
final class OutputRenderer: NSObject {
    private let composer: FrameComposer
    private var displayLink: CADisplayLink?

    // Metal / Core Image は使い回す(毎フレーム生成禁止)
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// 直近に取得できたソースフレーム(生のCIImage)。
    /// 新フレームがないtickではこれを使って「同じ絵を最新パラメータで再ワープ」する。
    private var lastFrame: CIImage?
    /// metalLayer.drawableSize の無駄な再設定を避けるための記録
    private var currentDrawableSize: CGSize = .zero

    /// レンダリング対象。ExternalSceneDelegateが接続時に設定する。
    weak var metalLayer: CAMetalLayer?
    /// フレーム供給元。ViewModelのcontentSource変更時に差し替わる。
    var source: FrameSource?
    /// 最新のRenderParametersスナップショットを返すクロージャ(スレッドセーフに実装すること)
    var paramsProvider: (() -> RenderParameters)?

    init(composer: FrameComposer) {
        self.composer = composer
        // iPadでは常にMetalが利用可能。生成失敗は環境不整合なので早期に落とす。
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metalデバイス/コマンドキューを生成できません")
        }
        self.device = device
        self.commandQueue = commandQueue
        // 動画は毎フレーム内容が変わるため中間キャッシュは無効化(WWDC20-10008)。
        // CIContextはMTLCommandQueueと同一にし、GPUのwaitバブルを避ける。
        self.ciContext = CIContext(mtlCommandQueue: commandQueue,
                                   options: [.cacheIntermediates: false])
        super.init()
    }

    // MARK: - ライフサイクル(start/stopは冪等)

    func start(on screen: UIScreen) {
        guard displayLink == nil else { return }   // 二重startを無視
        // 接続先ディスプレイのリフレッシュレートに同期したCADisplayLink
        let link = screen.displayLink(withTarget: self, selector: #selector(renderTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        guard let link = displayLink else { return }   // 二重stopを無視
        link.invalidate()
        displayLink = nil
    }

    // MARK: - 毎フレーム描画

    @objc private func renderTick(_ link: CADisplayLink) {
        guard let metalLayer, let paramsProvider else { return }

        var params = paramsProvider()
        guard params.canvasSize.width > 0, params.canvasSize.height > 0 else { return }

        // サーマル降格(N-THERM-1): レンダリング解像度をスケールする。
        // quadは正規化座標なのでcanvasSizeを縮めるだけで全体が比例縮小される。
        let scale = Self.thermalScale()
        let renderSize = CGSize(
            width: max(1, (params.canvasSize.width * scale).rounded(.down)),
            height: max(1, (params.canvasSize.height * scale).rounded(.down))
        )
        params.canvasSize = renderSize

        // CIContextで描画するための必須設定を防御的に反映(レイヤ生成はScene側の責務)
        if metalLayer.device == nil { metalLayer.device = device }
        metalLayer.framebufferOnly = false   // CIContextの描画に必要
        if currentDrawableSize != renderSize {
            metalLayer.drawableSize = renderSize   // 縮小分はレイヤが物理解像度へ拡大表示
            currentDrawableSize = renderSize
        }

        // 新フレームを取得。無ければ前フレームを再利用(最新パラメータで再ワープする)。
        if let newFrame = source?.copyFrame(forHostTime: link.targetTimestamp) {
            lastFrame = newFrame
        }
        guard let frame = lastFrame else { return }   // まだ1枚も来ていない

        let composed = composer.compose(frame: frame, params: params)

        // drawable取得に失敗したtickはスキップ(前フレームは表示されたまま)
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        ciContext.render(composed,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: composed.extent,
                         colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// thermalStateに応じた解像度スケール(.serious→75%, .critical→50%)
    private static func thermalScale() -> CGFloat {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: 0.5
        case .serious: 0.75
        default: 1.0
        }
    }
}
