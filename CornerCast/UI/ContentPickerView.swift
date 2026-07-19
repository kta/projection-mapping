import SwiftUI
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

    var body: some View {
        NavigationStack {
            List {
                Section("テストパターン") {
                    Button {
                        viewModel.contentSource = .testPattern
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
            }
            .navigationTitle("コンテンツ選択")
            .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - フォトライブラリ

    private func loadVideo(_ item: PhotosPickerItem) {
        isLoading = true
        Task {
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    await MainActor.run {
                        viewModel.contentSource = .video(movie.url)
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
                        viewModel.contentSource = .image(dest)
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
                    viewModel.contentSource = .video(dest)
                } else {
                    viewModel.contentSource = .image(dest)
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
