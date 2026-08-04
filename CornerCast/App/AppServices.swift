import Foundation

/// 依存の組み立てと共有(コンポジションルート)。
/// 外部ディスプレイシーンは環境注入(@UIApplicationDelegateAdaptor経由)が使えないため、
/// メイン/外部の両シーンがここから同一インスタンスを取得する。
@MainActor
final class AppServices {
    static let shared = AppServices()

    let presetStore: PresetStoreProtocol
    let viewModel: MappingViewModel
    let composer = FrameComposer()
    /// 再生パイプラインの所有者。外部ディスプレイの接続状態から独立している。
    let playback: PlaybackCoordinator
    let externalDisplayManager: ExternalDisplayManager
    /// 外部制御(OSC/MIDI)。永続化された設定に応じて起動時に自動起動する。
    let controlHub: ControlHub

    private init() {
        let store = PresetStore()
        self.presetStore = store
        let vm = MappingViewModel(presetStore: store)
        self.viewModel = vm

        let playback = PlaybackCoordinator(viewModel: vm)
        self.playback = playback
        vm.playback = playback

        self.externalDisplayManager = ExternalDisplayManager(
            viewModel: vm, composer: FrameComposer(), playback: playback)
        self.controlHub = ControlHub(viewModel: vm)

        // 起動時の状態に合わせてソースを組み立てる(未接続でもプレビューは動く)
        playback.reconcile()
    }

    /// アプリ起動完了時に一度だけ呼ぶ(AppDelegate から)。
    /// 永続化済みの設定に従って外部制御(F-CTRL-1)を起動する。
    /// これが無いと、設定は「有効」のままなのに待ち受けが立たず、
    /// 設定画面が「ON なのに停止中」という自己矛盾した表示になる。
    func applicationDidFinishLaunching() {
        controlHub.startIfEnabled()
    }
}
