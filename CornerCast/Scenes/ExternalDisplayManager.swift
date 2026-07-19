import UIKit
import Combine

/// 外部ディスプレイのライフサイクルとレンダリングパイプラインの結線を担う(F-OUT-3/4)。
/// シーンデリゲート(UIKit)とViewModel(SwiftUI世界)の橋渡し役。
///
/// TODO(TASK EXT-1 / 担当: scenes agent):
/// - externalSceneDidConnect: OutputRendererを生成しstart。
///   viewModel.displayState を isConnected=true / 解像度 / refreshRate で更新(MainActor)。
/// - externalSceneDidDisconnect: renderer.stop()、displayState更新。
/// - viewModel.contentSource / outputMode の変化を監視(withObservationTracking か
///   MainActorのタイマーポーリングでよい — 初版は簡潔さ優先)し、
///   FrameSourceの差し替え・OutputHostViewControllerのモード切替を行う。
/// - 未接続時のiPad内プレビュー(F-OUT-4)はUI側(MeshCanvasView)が担当するため、
///   本クラスは外部ディスプレイ専任。
@MainActor
final class ExternalDisplayManager {
    private let viewModel: MappingViewModel
    private let composer: FrameComposer
    private var renderer: OutputRenderer?

    init(viewModel: MappingViewModel, composer: FrameComposer) {
        self.viewModel = viewModel
        self.composer = composer
    }

    func externalSceneDidConnect(windowScene: UIWindowScene, host: OutputHostViewController) {
        // TODO: EXT-1
    }

    func externalSceneDidDisconnect() {
        // TODO: EXT-1
    }
}
