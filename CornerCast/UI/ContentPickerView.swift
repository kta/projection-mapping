import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// コンテンツ選択(F-SRC-1/2)。
///
/// TODO(TASK UI-2 / 担当: ui agent):
/// - 3択: フォトライブラリ(PhotosPicker) / ファイル(fileImporter) / テストパターン。
/// - PhotosPicker: matching .videos または .images。選択後、
///   itemProviderからURLをアプリのtmpにコピーして viewModel.contentSource を更新。
/// - fileImporter: allowedContentTypes [.movie, .image]。
///   セキュリティスコープ(startAccessingSecurityScopedResource)の取得と、
///   アプリサンドボックスへのコピーを忘れないこと。
/// - 読み込み失敗はアラート(N-REL-1: クラッシュさせない)。
struct ContentPickerView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Text("TODO: UI-2 ContentPickerView") // TODO: UI-2
    }
}
