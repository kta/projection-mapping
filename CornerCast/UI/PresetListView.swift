import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// プリセット管理画面(F-PRESET-1/3)。
///
/// 実装方針(TASK UI-2):
/// - List: PresetStore.listPresets()。行タップで読み込み、スワイプ削除、名前変更。
/// - 「現在の状態を保存」ボタン(名前入力)。
/// - JSON書き出し(ShareLink)/読み込み(fileImporter)(F-PRESET-3)。
///
/// 注意: bodyの型チェック時間爆発を避けるため、セクション・Binding・行ビューを
/// 小さな部品へ分割している(CIで実測したコンパイルエラーへの対処)。安易に統合しないこと。
struct PresetListView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var presets: [MappingPreset] = []
    @State private var showSaveDialog = false
    @State private var newName = ""
    @State private var renaming: MappingPreset?
    @State private var renameText = ""
    @State private var showImporter = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    /// 削除確認の対象。確認を挟まずに消さない(取り消せないため)。
    @State private var pendingDeletion: MappingPreset?
    /// 読み込み時に値を丸めた場合の通知
    @State private var noticeMessage: String?

    private var store: PresetStoreProtocol { AppServices.shared.presetStore }

    var body: some View {
        NavigationStack {
            listContent
                .navigationTitle("プリセット")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
                .onAppear {
                    reload()
                    prepareExport()
                }
        }
    }

    private var listContent: some View {
        List {
            actionsSection
            savedPresetsSection
        }
        // 削除は取り消せないため必ず確認する(F-PRESET-1の資産を守る)
        .confirmationDialog(
            pendingDeletion.map { "「\($0.name)」を削除しますか?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let target = pendingDeletion { delete(target) }
                pendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("この操作は取り消せません。")
        }
        .alert("読み込みました",
               isPresented: Binding(get: { noticeMessage != nil },
                                    set: { if !$0 { noticeMessage = nil } })) {
            Button("OK") { noticeMessage = nil; dismiss() }
        } message: {
            Text(noticeMessage ?? "")
        }
        .modifier(PresetListDialogs(
            showSaveDialog: $showSaveDialog,
            newName: $newName,
            renamePresented: renamePresented,
            renameText: $renameText,
            showImporter: $showImporter,
            errorPresented: errorPresented,
            errorMessage: errorMessage,
            onSave: saveCurrent,
            onRename: commitRename,
            onImport: importJSON
        ))
    }

    // MARK: - セクション

    private var actionsSection: some View {
        Section {
            Button {
                newName = viewModel.preset.name
                showSaveDialog = true
            } label: {
                Label("現在の状態を保存", systemImage: "square.and.arrow.down")
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("現在のプリセットを書き出し", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                showImporter = true
            } label: {
                Label("JSONを読み込み", systemImage: "tray.and.arrow.down")
            }
        }
    }

    private var savedPresetsSection: some View {
        Section("保存済みプリセット") {
            if presets.isEmpty {
                Text("保存済みのプリセットはありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(presets) { preset in
                presetRow(preset)
            }
        }
    }

    private func presetRow(_ preset: MappingPreset) -> some View {
        Button {
            viewModel.preset = preset
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .foregroundStyle(.primary)
                Text(preset.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // allowsFullSwipe: false は必須。既定(true)だと**最初に宣言したアクションが
        // フルスワイプで発火する**ため、行を勢いよく引くだけでタップ0回でプリセットが消える。
        // 削除は確認ダイアログを必ず挟む(取り消し手段が無いため)。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletion = preset
            } label: {
                Label("削除", systemImage: "trash")
            }
            Button {
                renaming = preset
                renameText = preset.name
            } label: {
                Label("名前変更", systemImage: "pencil")
            }
            .tint(.blue)
        }
        // マウス・トラックパッド(Mac Catalyst / iPadOSのポインタ)にはスワイプが無い。
        // 同じ操作へ到達できる経路をコンテキストメニューでも用意する。
        .contextMenu {
            Button {
                renaming = preset
                renameText = preset.name
            } label: {
                Label("名前変更", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDeletion = preset
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    // MARK: - Binding(型チェック分割のため計算プロパティ化)

    private var renamePresented: Binding<Bool> {
        Binding(get: { renaming != nil },
                set: { if !$0 { renaming = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
    }

    // MARK: - ロジック

    private func reload() {
        presets = store.listPresets()
    }

    /// 現在の状態を名前付きプリセットとして保存する。
    ///
    /// **同名の既存プリセットがあれば上書きする。** 常に新しいUUIDを振ると、
    /// 本番前日に保存した「本番用」を当日調整して保存し直したときに同名が2行に増え、
    /// どちらが最新か時刻でしか分からなくなる(そして片方を消すと当日版を失う)。
    private func saveCurrent() {
        let name = newName.isEmpty ? "新しいプリセット" : newName
        var p = viewModel.preset
        // 同名が既にあればそのIDを引き継いで上書き。無ければ新規として発番する。
        p.id = presets.first { $0.name == name }?.id ?? UUID()
        p.name = name
        p.updatedAt = .now
        do {
            try store.save(p)
            // 以後の自動保存が同じプリセットを指すよう、編集中の実体にもIDを反映する
            viewModel.preset.id = p.id
            viewModel.preset.name = p.name
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ preset: MappingPreset) {
        do {
            try store.delete(id: preset.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 同一idのまま名前だけ変更して保存
    private func commitRename() {
        guard var p = renaming else { return }
        p.name = renameText
        p.updatedAt = .now
        do {
            try store.save(p)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        renaming = nil
    }

    /// 現在のプリセットをtmpにJSON書き出しし、ShareLink対象にする(F-PRESET-3)
    private func prepareExport() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(viewModel.preset)
            let safeName = viewModel.preset.name.replacingOccurrences(of: "/", with: "_")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(safeName.isEmpty ? "preset" : safeName)
                .appendingPathExtension("json")
            try data.write(to: url)
            exportURL = url
        } catch {
            exportURL = nil
        }
    }

    /// JSONプリセットを読み込んで現在のプリセットに適用(F-PRESET-3)
    private func importJSON(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let src = urls.first else { return }
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: src)
                // **ここで JSONDecoder を直に使わないこと。**
                // ストア経由にすることで schemaVersion のゲートと値域・件数の正規化を必ず通す。
                // 迂回すると、このビルドが読めない値や gamma=0 のような値がそのまま
                // lastUsed.json へ焼き付き、再起動しても直らなくなる。
                let result = try store.decodeImported(data)
                viewModel.preset = result.preset
                if result.adjusted {
                    noticeMessage = "一部の値が有効範囲を超えていたため調整しました。"
                } else {
                    dismiss()
                }
            } catch {
                errorMessage = "プリセットを読み込めませんでした: \(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

/// ダイアログ・シート群をまとめたModifier。bodyの式を小さく保つための分割。
private struct PresetListDialogs: ViewModifier {
    @Binding var showSaveDialog: Bool
    @Binding var newName: String
    var renamePresented: Binding<Bool>
    @Binding var renameText: String
    @Binding var showImporter: Bool
    var errorPresented: Binding<Bool>
    var errorMessage: String?
    var onSave: () -> Void
    var onRename: () -> Void
    var onImport: (Result<[URL], Error>) -> Void

    func body(content: Content) -> some View {
        content
            .alert("プリセット名", isPresented: $showSaveDialog) {
                TextField("名前", text: $newName)
                Button("保存", action: onSave)
                Button("キャンセル", role: .cancel) {}
            }
            .alert("名前変更", isPresented: renamePresented) {
                TextField("名前", text: $renameText)
                Button("保存", action: onRename)
                Button("キャンセル", role: .cancel) {}
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false,
                          onCompletion: onImport)
            .alert("エラー", isPresented: errorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }
}
