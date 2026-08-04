import SwiftUI
import Foundation
import PhotosUI
import UniformTypeIdentifiers

/// コンテンツ選択(F-SRC-1/2)。
///
/// 実装方針(TASK UI-2):
/// - 3択: フォトライブラリ(PhotosPicker) / ファイル(fileImporter) / テストパターン。
/// - PhotosPicker(動画/画像)で選んだアイテムはアプリのtmpにコピーしてから contentSource を更新。
/// - fileImporterはセキュリティスコープを取得しサンドボックスへコピー。
/// - 読み込み失敗はアラート(N-REL-1: クラッシュさせない)。
struct ContentPickerView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var videoItem: PhotosPickerItem?
    @State private var imageItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    // ベイク済み動画の選択(F-BAKE-2/3)
    @State private var bakes: [BakeRecord] = []
    private let bakeStore = BakeStore()

    var body: some View {
        NavigationStack {
            List {
                sampleSection
                Section("テストパターン") {
                    Button {
                        viewModel.selectContent(.testPattern)
                        dismiss()
                    } label: {
                        Label("テストパターンを表示", systemImage: "grid")
                    }
                }
                Section("フォトライブラリ") {
                    PhotosPicker(selection: $videoItem, matching: .videos) {
                        Label("動画を選択", systemImage: "film")
                    }
                    PhotosPicker(selection: $imageItem, matching: .images) {
                        Label("画像を選択", systemImage: "photo")
                    }
                }
                Section("ファイル") {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("ファイルから読み込み", systemImage: "folder")
                    }
                }
                bakedSection
            }
            .navigationTitle("コンテンツ選択")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { bakes = bakeStore.list() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("読み込み中…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.movie, .image],
                          allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
            .onChange(of: videoItem) { _, newValue in
                if let item = newValue { loadVideo(item) }
            }
            .onChange(of: imageItem) { _, newValue in
                if let item = newValue { loadImage(item) }
            }
            .alert("読み込みエラー",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - サンプル動画(F-SRC-7)

    /// 同梱サンプル。自分の動画がなくてもワンタップで投影を試せる。
    @ViewBuilder private var sampleSection: some View {
        if !SampleVideo.available.isEmpty {
            Section("サンプル動画(そのまま使えます)") {
                ForEach(SampleVideo.available) { sample in
                    Button {
                        guard let url = sample.url else { return }
                        viewModel.selectContent(.video(url))
                        dismiss()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.title)
                                    .foregroundStyle(.primary)
                                Text(sample.caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: sample.systemImage)
                        }
                    }
                }
            }
        }
    }

    // MARK: - ベイク済み動画(F-BAKE-2/3)

    @ViewBuilder private var bakedSection: some View {
        Section("ベイク済み動画(低負荷再生)") {
            if bakes.isEmpty {
                Text("ベイク済み動画はありません。動画を選択後、下部の「この設定で書き出し」から作成できます。")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            ForEach(bakes) { record in
                bakeRow(record)
            }
        }
    }

    private func bakeRow(_ record: BakeRecord) -> some View {
        Button {
            // 結線契約(docs/05 §3-7): ベイク再生はUI側がcontentSourceとoutputModeを設定する
            viewModel.selectContent(.bakedVideo(record.fileURL))
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.sourceFileName)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Text("\(record.outputWidth)×\(record.outputHeight)")
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if bakeStore.isStale(record, currentPreset: viewModel.preset) {
                        Label("再書き出し推奨", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                try? bakeStore.delete(id: record.id)
                bakes = bakeStore.list()
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    // MARK: - フォトライブラリ

    private func loadVideo(_ item: PhotosPickerItem) {
        isLoading = true
        Task {
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    await MainActor.run {
                        Self.cleanupOldImports(keeping: movie.url)
                        viewModel.selectContent(.video(movie.url))
                        isLoading = false
                        dismiss()
                    }
                } else {
                    await finish(error: "動画を読み込めませんでした")
                }
            } catch {
                await finish(error: error.localizedDescription)
            }
        }
    }

    private func loadImage(_ item: PhotosPickerItem) {
        isLoading = true
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
                    let dest = Self.tmpURL(ext: ext)
                    try data.write(to: dest)
                    await MainActor.run {
                        Self.cleanupOldImports(keeping: dest)
                        viewModel.selectContent(.image(dest))
                        isLoading = false
                        dismiss()
                    }
                } else {
                    await finish(error: "画像を読み込めませんでした")
                }
            } catch {
                await finish(error: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func finish(error: String) {
        isLoading = false
        errorMessage = error
    }

    // MARK: - ファイル

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let src = urls.first else { return }
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            do {
                let dest = Self.tmpURL(ext: src.pathExtension.isEmpty ? "dat" : src.pathExtension)
                try FileManager.default.copyItem(at: src, to: dest)
                let type = UTType(filenameExtension: src.pathExtension)
                if let type, type.conforms(to: .movie) {
                    Self.cleanupOldImports(keeping: dest)
                        viewModel.selectContent(.video(dest))
                } else {
                    Self.cleanupOldImports(keeping: dest)
                        viewModel.selectContent(.image(dest))
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - ヘルパー

    /// アプリtmpに一意なファイルURLを作る
    private static func tmpURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    /// 取り込み済みの古いtmpコピーを掃除する。
    ///
    /// 取り込みは毎回UUID名で**原寸コピー**を作るので、候補の動画を何本か見比べただけで
    /// 数GBがtmpに残り続ける。OSの回収を待つとベイクの空き容量チェックが
    /// 自分の残骸に圧迫されて失敗しうるため、新しく取り込んだ時点で前のものを消す。
    /// 現在使用中のURLだけは必ず残すこと。
    private static func cleanupOldImports(keeping current: URL?) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let urls = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        let mediaExtensions: Set<String> = ["mov", "mp4", "m4v", "jpg", "jpeg", "png", "heic"]
        for url in urls where mediaExtensions.contains(url.pathExtension.lowercased()) {
            guard url != current else { continue }
            // 取り込みが作るのはUUID名のみ。それ以外(ガイドPNG等)は触らない。
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
                continue
            }
            try? fm.removeItem(at: url)
        }
    }
}

/// PhotosPickerの動画をアプリtmpへコピーして取り出すためのTransferable。
/// (動画はURLを直接loadTransferableできないため、FileRepresentationでコピーする定番パターン)
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty
                                        ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}
