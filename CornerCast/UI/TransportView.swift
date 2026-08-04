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

    // 再生制御は PlaybackCoordinator へ委譲する。
    // **再生状態をUIローカルに持たないこと。** 以前は isPlaying を自前でトグルしてから
    // nil かもしれないソースへ委譲していたため、ソースが無いときにアイコンだけ
    // 一時停止へ変わり「再生中」と表示し続ける嘘が発生していた。
    private var playback: PlaybackCoordinator? { viewModel.playback }

    /// シーク操作中の一時値。ドラッグ中だけスライダを手元の値で描く。
    @State private var seekPosition: Double = 0
    @State private var isSeeking = false

    // ベイク
    @State private var bakeStore = BakeStore()
    /// 陳腐化バッジ(F-BAKE-3)の判定結果。body評価のたびに index.json を
    /// 同期読みしないようキャッシュする(投影のCADisplayLinkと同じランループを塞ぐため)。
    @State private var hasStaleBake = false
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
            // 再生/一時停止。状態は必ず実プレイヤから読む。
            Button {
                playback?.togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .disabled(!canControl)
            .accessibilityLabel(isPlaying ? "一時停止" : "再生")

            // シーク(ドラッグ確定時に実尺換算でシークする)
            Slider(value: sliderBinding, in: 0...1) { editing in
                isSeeking = editing
                if !editing { playback?.seek(toFraction: seekPosition) }
            }
            .disabled(!canControl)
            .accessibilityLabel("再生位置")

            // 操作できないときは黙って無効化せず、理由を1行で示す(無言の無効化にしない)
            if let reason = playback?.unavailableReason, !canControl {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        // 音量変更をリアルタイム・ベイクどちらの経路にも即時反映する
        .onChange(of: viewModel.preset.volume) { _, v in
            playback?.applyVolume(v)
        }
        // ループ設定はプレイヤ構築時に決まるので、変更時は組み直す
        .onChange(of: viewModel.preset.loop) { _, _ in
            playback?.applyLoopSetting()
        }
        // 陳腐化判定はファイルI/Oを伴うので body から追い出し、関係する変化時のみ再計算する
        .task(id: viewModel.preset.calibrationFingerprint) {
            hasStaleBake = bakeStore.list().contains {
                bakeStore.isStale($0, currentPreset: viewModel.preset)
            }
        }
        .overlay { if isExporting { exportOverlay } }
        .confirmationDialog("書き出し解像度", isPresented: $showBakeDialog, titleVisibility: .visible) {
            Button("1080p (1920×1080)") { startBake(size: CGSize(width: 1920, height: 1080)) }
            Button("4K (3840×2160)") { startBake(size: CGSize(width: 3840, height: 2160)) }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("書き出し完了", isPresented: $showCompletionAlert) {
            Button("ベイク再生に切替") {
                // selectContent が outputMode との整合を面倒みる(個別に書き換えない)
                if let record = lastBakeRecord {
                    viewModel.selectContent(.bakedVideo(record.fileURL))
                }
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
        if hasStaleBake {
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
        // 無言でグレーアウトしない。書き出せない理由を示す。
        .help(bakeableURL == nil ? "動画を選ぶと書き出せます" : "")
        if bakeableURL == nil && !isExporting {
            Text("動画を選ぶと書き出せます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    // MARK: 再生状態(すべて PlaybackCoordinator 由来)

    private var isPlaying: Bool { playback?.isPlaying ?? false }
    private var canControl: Bool { playback?.canControlPlayback ?? false }

    /// ドラッグ中は手元の値、それ以外は実プレイヤの位置を返す
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isSeeking ? seekPosition : (playback?.positionFraction ?? 0) },
            set: { seekPosition = $0 }
        )
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

}
