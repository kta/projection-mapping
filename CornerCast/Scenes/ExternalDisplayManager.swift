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
    private var renderer: OutputRenderer?

    // MARK: 接続状態
    private weak var host: OutputHostViewController?
    private var screen: UIScreen?
    private var canvasSize: CGSize = .zero

    // MARK: ソース
    /// 現在の実時間ソース。動画は停止のため型付き参照を保持する。
    private var videoSource: VideoSource?
    /// テストパターンは毎フレームのparamsをupdate(params:)で渡す必要があるため型付き参照を保持する。
    private var testPattern: TestPatternGenerator?

    // MARK: ベイク再生
    private var bakedPlayer: AVQueuePlayer?
    private var bakedLooper: AVPlayerLooper?

    // MARK: 監視(ポーリング)
    private var syncTask: Task<Void, Never>?
    private var lastContentSource: MappingViewModel.ContentSource?
    private var lastOutputMode: MappingViewModel.OutputMode?

    /// レンダラ(バックグラウンドのCADisplayLinkスレッド)へ渡す最新スナップショット。
    /// MainActorから書き込み、レンダラ側から読み出すためロックで保護する。
    private let paramsBox = OSAllocatedUnfairLock<RenderParameters?>(initialState: nil)

    init(viewModel: MappingViewModel, composer: FrameComposer) {
        self.viewModel = viewModel
        self.composer = composer
    }

    // MARK: - 接続 / 切断

    func externalSceneDidConnect(windowScene: UIWindowScene, host: OutputHostViewController) {
        let screen = windowScene.screen
        self.screen = screen
        self.host = host

        // 出力解像度(F-OUT-5): currentModeのピクセルサイズを優先し、無ければbounds×scaleで代替。
        let resolution = screen.currentMode?.size
            ?? CGSize(width: screen.bounds.width * screen.scale,
                      height: screen.bounds.height * screen.scale)
        self.canvasSize = resolution
        host.metalLayer.drawableSize = resolution

        let refreshRate = Double(screen.maximumFramesPerSecond)

        // 接続状態を反映(F-OUT-3)
        viewModel.displayState = MappingViewModel.DisplayState(
            isConnected: true, resolution: resolution, refreshRate: refreshRate)

        // レンダラ生成・結線
        let r = OutputRenderer(composer: composer)
        r.metalLayer = host.metalLayer
        r.paramsProvider = { [paramsBox, resolution] in
            // ViewModelを直接触らず、ロック保護済みの最新スナップショットを返す。
            paramsBox.withLock { $0 } ?? RenderParameters(canvasSize: resolution, preset: .makeDefault())
        }
        self.renderer = r

        // レンダラ開始前にboxを埋めておく。
        pushParams()

        // 現在のcontentSource/outputModeに合わせて結線し、変化検知の基準を設定。
        lastContentSource = viewModel.contentSource
        lastOutputMode = viewModel.outputMode
        reconfigure()

        startSyncLoop()
    }

    func externalSceneDidDisconnect() {
        stopSyncLoop()
        renderer?.stop()
        renderer = nil
        stopBakedPlayback()
        videoSource?.pause()
        videoSource = nil
        testPattern = nil
        host = nil
        screen = nil
        canvasSize = .zero
        lastContentSource = nil
        lastOutputMode = nil
        paramsBox.withLock { $0 = nil }

        viewModel.displayState = MappingViewModel.DisplayState()
    }

    // MARK: - パラメータ同期(ドラッグ即反映)

    private func currentParams() -> RenderParameters {
        viewModel.renderParameters(canvasSize: canvasSize)
    }

    private func pushParams() {
        let params = currentParams()
        paramsBox.withLock { $0 = params }
        // テストパターンはcrop構成の変化を検知して再生成する(quad変化ではparamsのみ更新)。
        testPattern?.update(params: params)
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

        let contentChanged = viewModel.contentSource != lastContentSource
        let modeChanged = viewModel.outputMode != lastOutputMode
        if contentChanged || modeChanged {
            lastContentSource = viewModel.contentSource
            lastOutputMode = viewModel.outputMode
            reconfigure()
        }
    }

    // MARK: - 結線(モード / ソース切替)

    /// 現在の outputMode / contentSource に合わせてパイプラインを組み替える。
    /// 変化検知後にのみ呼ぶこと(プレイヤやソースを毎回作り直すため)。
    private func reconfigure() {
        // 直前の実時間ソースを停止
        videoSource?.pause()
        videoSource = nil
        testPattern = nil

        switch viewModel.outputMode {
        case .bakedPlayback:
            // ベイク再生はHWデコードのみ。CADisplayLink駆動のレンダラは止める(N-THERM-1)。
            renderer?.stop()
            renderer?.source = nil
            startBakedPlayback()

        case .realtime:
            stopBakedPlayback()
            host?.setMode(.realtime)
            renderer?.source = makeRealtimeSource(from: viewModel.contentSource)
            if let screen { renderer?.start(on: screen) }   // start()は冪等
        }
    }

    private func makeRealtimeSource(from content: MappingViewModel.ContentSource) -> FrameSource? {
        switch content {
        case .none:
            return nil
        case .testPattern:
            let tp = TestPatternGenerator()
            tp.update(params: currentParams())
            testPattern = tp
            return tp
        case .image(let url):
            return StillImageSource(url: url)
        case .video(let url):
            let vs = VideoSource(url: url, loop: viewModel.preset.loop)
            vs.volume = Float(viewModel.preset.volume)
            vs.play()
            videoSource = vs
            return vs
        case .bakedVideo:
            // ベイク済み動画はベイク再生モード(AVPlayerLayer)で扱う。実時間パスでは表示しない。
            return nil
        }
    }

    private func startBakedPlayback() {
        host?.setMode(.bakedPlayback)
        guard case let .bakedVideo(url) = viewModel.contentSource else {
            // ベイク動画が未選択。黒画面のまま待機。
            return
        }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        if viewModel.preset.loop {
            // シームレスループ(F-SRC-3)
            bakedLooper = AVPlayerLooper(player: queue, templateItem: item)
        } else {
            queue.insert(item, after: nil)
        }
        queue.volume = Float(viewModel.preset.volume)
        bakedPlayer = queue
        host?.player = queue
        queue.play()
    }

    private func stopBakedPlayback() {
        bakedPlayer?.pause()
        bakedLooper?.disableLooping()
        bakedLooper = nil
        bakedPlayer = nil
        host?.player = nil
    }
}
