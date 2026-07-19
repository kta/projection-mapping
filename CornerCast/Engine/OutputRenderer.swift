import CoreImage
import Metal
import QuartzCore
import UIKit

/// リアルタイムモードのレンダラ(F-RT-1): CADisplayLink駆動で
/// FrameSource → FrameComposer → CAMetalLayer に毎フレーム描画する。
///
/// TODO(TASK ENG-3 / 担当: engine agent):
/// 実装要点(設計書§3.3・§5、調査レポート§2の確定事項):
/// - CIContextは1つを生成して保持(毎フレーム生成禁止)。
///   CIContext(mtlDevice:options:[.cacheIntermediates: false])。
/// - CADisplayLinkは「外部ディスプレイのUIScreen」から生成する
///   (screen.displayLink(withTarget:selector:) — 接続先リフレッシュレートに同期)。
/// - 毎tick: source.copyFrame → paramsProvider() → composer.compose →
///   metalLayer.nextDrawable → ciContext.render(_:to:commandBuffer:bounds:colorSpace:) → present。
///   新フレームがnilなら前回のcomposed結果を再利用(パラメータが変わった場合があるため
///   ワープは再実行する)。drawable取得失敗時はそのtickをスキップ。
/// - metalLayer.drawableSize は外部画面のピクセル解像度に設定(F-OUT-5)。
/// - サーマル対応(N-THERM-1): ProcessInfo.thermalStateを監視し、
///   .serious以上でレンダリング解像度を75%→50%に段階降格(canvasSizeをスケール)。
/// - start()/stop() は冪等にする(シーン切断で二重stopが起こり得る)。
/// - paramsProviderはMainActorのViewModelを直接触らず、値型スナップショットを受け取る。
///   スナップショットの受け渡しはロック(OSAllocatedUnfairLock)経由で行う。
final class OutputRenderer {
    private let composer: FrameComposer
    private var displayLink: CADisplayLink?

    /// レンダリング対象。ExternalSceneDelegateが接続時に設定する。
    weak var metalLayer: CAMetalLayer?
    /// フレーム供給元。ViewModelのcontentSource変更時に差し替わる。
    var source: FrameSource?
    /// 最新のRenderParametersスナップショットを返すクロージャ(スレッドセーフに実装すること)
    var paramsProvider: (() -> RenderParameters)?

    init(composer: FrameComposer) {
        self.composer = composer
    }

    func start(on screen: UIScreen) {
        // TODO: ENG-3
    }

    func stop() {
        // TODO: ENG-3
    }
}
