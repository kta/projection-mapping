import AVFoundation
import CoreImage
import Foundation
import Observation
import UIKit

/// 再生パイプラインの所有者(F-SRC-3/4 / F-RT-1 / F-BAKE-2)。
///
/// **外部ディスプレイの接続状態から独立していること**が本クラスの存在意義である。
/// 以前は `ExternalDisplayManager` が `VideoSource` を生成しており、
/// プロジェクターを繋いでいない間は再生・シーク・音量が一切効かず、
/// しかも再生ボタンのアイコンだけが切り替わって「再生中」と嘘をついていた。
/// ベイク再生モードでも同じ穴があり、長時間投影の既定モードで一時停止すらできなかった。
///
/// 責務:
/// - contentSource / outputMode に追随して、実時間ソースとベイク用プレイヤを組み替える
/// - リアルタイム/ベイクの区別なく、単一のトランスポート API を公開する
/// - 再生状態は**必ず実プレイヤから導出する**(UI側のローカル状態を信用しない)
/// - AVAudioSession の設定と割り込み復帰(電話・Siri)
/// - フォアグラウンド復帰時の再生状態復元(N-REL-1)
///
/// `ExternalDisplayManager` は本クラスが用意したソースを**表示するだけ**になる。
@MainActor
@Observable
final class PlaybackCoordinator {

    private weak var viewModel: MappingViewModel?

    // MARK: 実時間ソース(リアルタイムモード)

    /// レンダラとエディタプレビューが共有するフレーム供給元。
    @ObservationIgnored private(set) var realtimeSource: FrameSource?
    @ObservationIgnored private var videoSource: VideoSource?
    @ObservationIgnored private var testPattern: TestPatternGenerator?

    // MARK: ベイク再生

    @ObservationIgnored private(set) var bakedPlayer: AVQueuePlayer?
    @ObservationIgnored private var bakedLooper: AVPlayerLooper?

    // MARK: 公開する再生状態(すべて実プレイヤ由来)

    /// 実際に再生中か。UI はこれを表示する(自前でトグルしないこと)。
    private(set) var isPlaying = false
    /// 0-1 の再生位置。尺が取れない間は 0。
    private(set) var positionFraction: Double = 0
    /// 尺(秒)。取得できない間は 0。
    private(set) var duration: Double = 0
    /// トランスポートを操作できるか。false のときUIは操作を無効化し、理由を示すこと。
    private(set) var canControlPlayback = false
    /// 操作できない理由(UIに1行で出す)。操作できるときは nil。
    private(set) var unavailableReason: String?

    // MARK: 観測

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    /// バックグラウンド遷移時に「再生中だったか」を覚えておき、復帰時に戻す(N-REL-1)
    @ObservationIgnored private var wasPlayingBeforeBackground = false

    init(viewModel: MappingViewModel) {
        self.viewModel = viewModel
        configureAudioSession()
        observeInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - オーディオセッション

    /// カテゴリ未設定の既定は `soloAmbient` で、消音スイッチで無音になり、
    /// 他アプリの音声と排他になり、画面ロックで止まる。投影用途では `playback` が正しい。
    private func configureAudioSession() {
        #if !targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        #endif
    }

    /// 電話・Siri・アラームによる割り込みからの復帰。
    /// これらはシーンのライフサイクル遷移を伴わない経路があるため、専用に購読する。
    private func observeInterruptions() {
        #if !targetEnvironment(macCatalyst)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    self.refreshTransportState()
                case .ended:
                    let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    if options.contains(.shouldResume) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.play()
                    } else {
                        self.refreshTransportState()
                    }
                @unknown default:
                    self.refreshTransportState()
                }
            }
        }
        #endif
    }

    // MARK: - 組み替え

    /// contentSource / outputMode の変化に追随してパイプラインを組み替える。
    /// ViewModel の didSet から呼ばれる。冪等ではない(毎回プレイヤを作り直す)ので
    /// 実際に値が変わったときだけ呼ぶこと。
    func reconcile() {
        guard let viewModel else { return }

        teardownRealtime()
        stopBakedPlayback()

        switch viewModel.outputMode {
        case .bakedPlayback:
            startBakedPlayback()
        case .realtime:
            realtimeSource = makeRealtimeSource(from: viewModel.contentSource)
        }

        attachObservers()
        refreshTransportState()
    }

    /// テストパターンは毎フレームのパラメータに依存して描かれるため、外から更新を流す。
    func update(params: RenderParameters) {
        testPattern?.update(params: params)
    }

    private func teardownRealtime() {
        videoSource?.pause()
        videoSource = nil
        testPattern = nil
        realtimeSource = nil
    }

    private func makeRealtimeSource(from content: MappingViewModel.ContentSource) -> FrameSource? {
        guard let viewModel else { return nil }
        switch content {
        case .none:
            return nil
        case .testPattern:
            let tp = TestPatternGenerator()
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
            // ベイク済み動画は合成済み。実時間パスで再ワープしてはいけない。
            return nil
        }
    }

    private func startBakedPlayback() {
        guard let viewModel,
              case let .bakedVideo(url) = viewModel.contentSource else { return }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        if viewModel.preset.loop {
            bakedLooper = AVPlayerLooper(player: queue, templateItem: item)
        } else {
            queue.insert(item, after: nil)
        }
        queue.volume = Float(viewModel.preset.volume)
        bakedPlayer = queue
        queue.play()
    }

    private func stopBakedPlayback() {
        bakedPlayer?.pause()
        bakedLooper?.disableLooping()
        bakedLooper = nil
        bakedPlayer = nil
    }

    // MARK: - トランスポート(リアルタイム / ベイク共通)

    /// 現在操作対象のプレイヤ。モードによって実体が変わる。
    private var activePlayer: AVPlayer? {
        guard let viewModel else { return nil }
        switch viewModel.outputMode {
        case .bakedPlayback: return bakedPlayer
        case .realtime: return videoSource?.player
        }
    }

    func play() {
        activePlayer?.play()
        refreshTransportState()
    }

    func pause() {
        activePlayer?.pause()
        refreshTransportState()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(toFraction fraction: Double) {
        guard let player = activePlayer, duration.isFinite, duration > 0 else { return }
        let seconds = min(max(fraction, 0), 1) * duration
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// preset.volume の変更を、リアルタイム・ベイクどちらの経路にも反映する。
    func applyVolume(_ volume: Double) {
        let v = Float(min(max(volume, 0), 1))
        videoSource?.volume = v
        bakedPlayer?.volume = v
    }

    /// preset.loop の変更を反映する。ループ設定はプレイヤ構築時に決まるので作り直す。
    func applyLoopSetting() {
        reconcile()
    }

    // MARK: - 状態の観測(UIのローカル状態を信用しない)

    private func attachObservers() {
        detachObservers()
        guard let player = activePlayer else { return }
        observedPlayer = player

        // 再生位置。0.25秒ごとで十分(シークバーの粒度)。
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTransportState() }
        }

        // 再生/停止はシステム側でも変わる(ループ折り返し・割り込み・外部制御)ので必ず購読する。
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshTransportState() }
        }
    }

    private func detachObservers() {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = nil
        statusObservation = nil
    }

    /// 公開状態を実プレイヤから導出し直す。
    private func refreshTransportState() {
        guard let player = activePlayer else {
            isPlaying = false
            positionFraction = 0
            duration = 0
            canControlPlayback = false
            unavailableReason = Self.reasonForUnavailable(viewModel)
            return
        }
        canControlPlayback = true
        unavailableReason = nil
        isPlaying = player.timeControlStatus == .playing

        let total = player.currentItem?.duration.seconds ?? 0
        if total.isFinite, total > 0 {
            duration = total
            positionFraction = min(max(player.currentTime().seconds / total, 0), 1)
        } else {
            duration = 0
            positionFraction = 0
        }
    }

    /// 「なぜ操作できないのか」をユーザーの言葉で返す。無言の無効化にしないため。
    private static func reasonForUnavailable(_ viewModel: MappingViewModel?) -> String? {
        guard let viewModel else { return nil }
        switch viewModel.contentSource {
        case .none:
            return "コンテンツが選ばれていません"
        case .testPattern:
            return "テストパターンには再生位置がありません"
        case .image:
            return "静止画には再生位置がありません"
        case .video:
            return viewModel.outputMode == .bakedPlayback
                ? "ベイク再生モードです。書き出した動画を選ぶと再生できます"
                : "動画を準備しています…"
        case .bakedVideo:
            return viewModel.outputMode == .realtime
                ? "書き出し済み動画はベイク再生モードで再生できます"
                : "動画を準備しています…"
        }
    }

    // MARK: - シーンのライフサイクル(N-REL-1)

    func sceneDidEnterBackground() {
        wasPlayingBeforeBackground = isPlaying
    }

    func sceneWillEnterForeground() {
        // 復帰時に投影が静止フレームで固まったままにならないよう、再生状態を戻す。
        if wasPlayingBeforeBackground {
            play()
        } else {
            refreshTransportState()
        }
    }
}
