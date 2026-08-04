import UIKit
import AVFoundation
import os

/// 外部ディスプレイのライフサイクルとレンダリングパイプラインの結線を担う(F-OUT-3/4)。
/// シーンデリゲート(UIKit)とViewModel(SwiftUI世界)の橋渡し役。
///
/// - externalSceneDidConnect: OutputRendererを生成しstart。displayStateを更新。
/// - externalSceneDidDisconnect: renderer.stop()、displayState更新。
/// - viewModel.contentSource / outputMode の変化を MainActor のポーリングで監視し、
///   FrameSourceの差し替え・OutputHostViewControllerのモード切替を行う(初版は簡潔さ優先)。
/// - 未接続時のiPad内プレビュー(F-OUT-4)はUI側(MeshCanvasView)が担当するため、本クラスは外部専任。
@MainActor
final class ExternalDisplayManager {
    private let viewModel: MappingViewModel
    private let composer: FrameComposer
    /// 再生パイプラインの所有者。ソースの生成・停止は一切こちらの責務ではない。
    private let playback: PlaybackCoordinator
    private var renderer: OutputRenderer?

    // MARK: 接続状態
    private weak var host: OutputHostViewController?
    private var screen: UIScreen?
    private var canvasSize: CGSize = .zero
    /// 解像度変更の購読(F-OUT-5)。プロジェクタは電源投入直後に1080pで応答し、
    /// 数秒後に4Kへ再ネゴシエートすることがある。この間シーンは切断されないので、
    /// 接続時に一度読んだきりだとドローアブルが実パネルと食い違ったままになる。
    private var modeChangeObserver: NSObjectProtocol?

    // MARK: 監視(ポーリング)
    private var syncTask: Task<Void, Never>?
    private var lastOutputMode: MappingViewModel.OutputMode?

    /// レンダラ(CADisplayLink)へ渡す最新スナップショット。
    /// MainActorから書き込み、レンダラ側から読み出すためロックで保護する。
    private let paramsBox = OSAllocatedUnfairLock<RenderParameters?>(initialState: nil)

    init(viewModel: MappingViewModel, composer: FrameComposer, playback: PlaybackCoordinator) {
        self.viewModel = viewModel
        self.composer = composer
        self.playback = playback
    }

    // MARK: - 接続 / 切断

    func externalSceneDidConnect(windowScene: UIWindowScene, host: OutputHostViewController) {
        let screen = windowScene.screen
        self.screen = screen
        self.host = host

        updateResolution(from: screen)

        // レンダラ生成・結線
        let r = OutputRenderer(composer: composer)
        r.metalLayer = host.metalLayer
        r.paramsProvider = { [paramsBox] in
            // ViewModelを直接触らず、ロック保護済みの最新スナップショットを返す。
            // フォールバックも「接続時の解像度」を焼き込まず、box が空なら描画をスキップさせる。
            paramsBox.withLock { $0 } ?? RenderParameters(canvasSize: .zero, preset: .makeDefault())
        }
        self.renderer = r

        // レンダラ開始前にboxを埋めておく。
        pushParams()

        lastOutputMode = viewModel.outputMode
        reconfigure()

        // 解像度の再ネゴシエートに追随する(F-OUT-5)
        modeChangeObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.modeDidChangeNotification, object: screen, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = self.screen else { return }
                self.updateResolution(from: screen)
                self.pushParams()
            }
        }

        // 投影中は画面を消灯させない(N-THERM-2)。条件は「投影中」であって
        // 「メインUIがアクティブ」ではない — Split View で他アプリに触れただけで
        // 自動ロックが復活し、上映が数分で止まってしまうため。
        UIApplication.shared.isIdleTimerDisabled = true

        startSyncLoop()
    }

    func externalSceneDidDisconnect() {
        stopSyncLoop()
        renderer?.stop()
        renderer = nil
        if let modeChangeObserver {
            NotificationCenter.default.removeObserver(modeChangeObserver)
        }
        modeChangeObserver = nil
        host = nil
        screen = nil
        canvasSize = .zero
        lastOutputMode = nil
        paramsBox.withLock { $0 = nil }

        viewModel.displayState = MappingViewModel.DisplayState()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// 出力解像度(F-OUT-5)を screen から読み直し、キャンバス・ドローアブル・表示状態へ反映する。
    /// 接続時とモード変更時の両方から呼ぶ。
    private func updateResolution(from screen: UIScreen) {
        let resolution = screen.currentMode?.size
            ?? CGSize(width: screen.bounds.width * screen.scale,
                      height: screen.bounds.height * screen.scale)
        guard resolution.width > 0, resolution.height > 0 else { return }
        canvasSize = resolution
        host?.metalLayer.drawableSize = resolution
        viewModel.displayState = MappingViewModel.DisplayState(
            isConnected: true,
            resolution: resolution,
            refreshRate: Double(screen.maximumFramesPerSecond))
    }

    // MARK: - パラメータ同期(ドラッグ即反映)

    private func currentParams() -> RenderParameters {
        viewModel.renderParameters(canvasSize: canvasSize)
    }

    private func pushParams() {
        let params = currentParams()
        paramsBox.withLock { $0 = params }
        // テストパターンはcrop構成の変化を検知して再生成する(quad変化ではparamsのみ更新)。
        playback.update(params: params)
    }

    // MARK: - 監視ループ

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                // 外部ディスプレイのリフレッシュより粗くてよい(≒60Hz)。UIトラッキング中も止まらない。
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopSyncLoop() {
        syncTask?.cancel()
        syncTask = nil
    }

    private func tick() {
        pushParams()

        // ソースの生成・停止は PlaybackCoordinator の責務。ここは表示レイヤの切替と
        // レンダラへのソース差し替えだけを追随させる。
        if viewModel.outputMode != lastOutputMode {
            lastOutputMode = viewModel.outputMode
            reconfigure()
            return
        }
        switch viewModel.outputMode {
        case .realtime:
            if !Self.isSame(renderer?.source, playback.realtimeSource) {
                renderer?.source = playback.realtimeSource
            }
        case .bakedPlayback:
            if host?.player !== playback.bakedPlayer {
                host?.player = playback.bakedPlayer
            }
        }
    }

    /// 参照同一性の比較(FrameSourceはプロトコルなので ObjectIdentifier で比べる)
    private static func isSame(_ a: FrameSource?, _ b: FrameSource?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return ObjectIdentifier(x) == ObjectIdentifier(y)
        default: return false
        }
    }

    // MARK: - 結線(表示モードの切替)

    /// 現在の outputMode に合わせて表示レイヤとレンダラを組み替える。
    private func reconfigure() {
        switch viewModel.outputMode {
        case .bakedPlayback:
            // ベイク再生はHWデコードのみ。CADisplayLink駆動のレンダラは止める(N-THERM-1)。
            renderer?.stop()
            renderer?.source = nil
            host?.setMode(.bakedPlayback)
            host?.player = playback.bakedPlayer

        case .realtime:
            host?.player = nil
            host?.setMode(.realtime)
            renderer?.source = playback.realtimeSource
            if let screen { renderer?.start(on: screen) }   // start()は冪等
        }
    }
}
