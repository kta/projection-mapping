import SwiftUI
import Foundation
import AVFoundation
import Combine

/// トランスポートバー(F-SRC-4)+ベイク操作(F-BAKE系)。
///
/// 実装方針(TASK UI-2):
/// - 再生/一時停止・シーク・ループ・音量。
/// - ベイク: 解像度選択→BakeExporter.export を Task 実行、進捗オーバーレイ+キャンセル。
/// - 完了後は .bakedPlayback への切替をアラート提案。stale時は再書き出しバッジ(F-BAKE-3)。
struct TransportView: View {
    @Bindable var viewModel: MappingViewModel

    // 再生制御は viewModel.activeVideoSource(ExternalDisplayManagerが結線時に設定)へ委譲する。
    // 再生状態の表示はUIローカルで保持する(ソース側に状態購読APIを持たせない割り切り)。
    @State private var isPlaying = false
    @State private var seekPosition: Double = 0
    /// シーク操作中はタイマー由来の位置更新でスライダを上書きしない
    @State private var isSeeking = false

    // ベイク
    @State private var bakeStore = BakeStore()
    @State private var showBakeDialog = false
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var exporter: BakeExporter?
    @State private var showCompletionAlert = false
    @State private var lastBakeRecord: BakeRecord?
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 16) {
            // 再生/一時停止
            Button {
                isPlaying.toggle()
                if isPlaying {
                    viewModel.activeVideoSource?.play()
                } else {
                    viewModel.activeVideoSource?.pause()
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }

            // シーク(ドラッグ確定時に実尺換算でシークする)
            Slider(value: $seekPosition, in: 0...1) { editing in
                isSeeking = editing
                if !editing { seek(toFraction: seekPosition) }
            }

            // ループ(F-SRC-3)。presetに永続化される。
            Toggle(isOn: $viewModel.preset.loop) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)

            // 音量(F-SRC-4)。presetに永続化される。
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $viewModel.preset.volume, in: 0...1)
                    .frame(width: 120)
            }

            Divider().frame(height: 24)

            bakeControls
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // 音量変更を再生中ソースへ即時反映(presetへの永続化はBinding側で行われる)
        .onChange(of: viewModel.preset.volume) { _, v in
            viewModel.activeVideoSource?.volume = Float(v)
        }
        // 再生位置・再生状態の定期反映(0.5秒間隔で十分)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            syncPlaybackUI()
        }
        .overlay { if isExporting { exportOverlay } }
        .confirmationDialog("書き出し解像度", isPresented: $showBakeDialog, titleVisibility: .visible) {
            Button("1080p (1920×1080)") { startBake(size: CGSize(width: 1920, height: 1080)) }
            Button("4K (3840×2160)") { startBake(size: CGSize(width: 3840, height: 2160)) }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("書き出し完了", isPresented: $showCompletionAlert) {
            Button("ベイク再生に切替") {
                // 結線契約: ベイク再生への切替時はUI側がcontentSourceも設定する
                // (ExternalDisplayManagerは .bakedVideo(url) を待ち受けるだけ)
                if let record = lastBakeRecord {
                    viewModel.contentSource = .bakedVideo(record.fileURL)
                }
                viewModel.outputMode = .bakedPlayback
            }
            Button("そのまま", role: .cancel) {}
        } message: {
            Text("合成済み動画の書き出しが完了しました。ベイク再生モードに切り替えますか?")
        }
        .alert("書き出しエラー",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: ベイク操作

    @ViewBuilder private var bakeControls: some View {
        if isStaleBakeExists {
            // F-BAKE-3: プリセット変更でベイクが陳腐化
            Label("再書き出しが必要", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Button {
            showBakeDialog = true
        } label: {
            Label("この設定で書き出し", systemImage: "square.and.arrow.down.on.square")
        }
        .disabled(bakeableURL == nil || isExporting)
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: exportProgress) {
                    Text("書き出し中… \(Int(exportProgress * 100))%")
                }
                .frame(width: 240)
                Button("キャンセル", role: .cancel) { cancelBake() }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: ロジック

    /// ベイク対象URL(動画ソースのときのみ)
    private var bakeableURL: URL? {
        if case .video(let url) = viewModel.contentSource { return url }
        return nil
    }

    /// 現在のプリセットに対して陳腐化しているベイクが存在するか(F-BAKE-3)
    private var isStaleBakeExists: Bool {
        bakeStore.list().contains { bakeStore.isStale($0, currentPreset: viewModel.preset) }
    }

    private func startBake(size: CGSize) {
        guard let url = bakeableURL else { return }
        let ex = BakeExporter(composer: AppServices.shared.composer)
        ex.progressHandler = { p in
            Task { @MainActor in exportProgress = p }
        }
        exporter = ex
        exportProgress = 0
        isExporting = true

        exportTask = Task {
            do {
                let record = try await ex.export(sourceURL: url,
                                                 preset: viewModel.preset,
                                                 outputSize: size)
                try? bakeStore.add(record)
                await MainActor.run {
                    lastBakeRecord = record
                    isExporting = false
                    showCompletionAlert = true
                }
            } catch is CancellationError {
                await MainActor.run { isExporting = false }
            } catch BakeError.cancelled {
                // ユーザー起因のキャンセルはエラー表示しない
                await MainActor.run { isExporting = false }
            } catch {
                await MainActor.run {
                    isExporting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelBake() {
        exporter?.cancel()
        exportTask?.cancel()
        isExporting = false
    }

    /// 0-1のシーク位置を実尺(秒)へ換算してシークする。尺が取れない間は何もしない。
    private func seek(toFraction fraction: Double) {
        guard let source = viewModel.activeVideoSource,
              let duration = source.player?.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        source.seek(to: fraction * duration)
    }

    /// 再生状態・再生位置をUIへ反映する(シーク操作中はスライダを触らない)
    private func syncPlaybackUI() {
        guard let player = viewModel.activeVideoSource?.player else { return }
        isPlaying = player.timeControlStatus == .playing
        guard !isSeeking,
              let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        seekPosition = min(max(player.currentTime().seconds / duration, 0), 1)
    }
}
