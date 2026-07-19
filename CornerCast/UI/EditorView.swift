import SwiftUI

/// メイン編集画面(要件§5の画面仕様)。
///
/// レイアウト(TASK UI-1):
///   NavigationStack {
///     VStack {
///       HStack { MeshCanvasView(≒左) / InspectorView(右280pt固定) }
///       TransportView
///     }
///     .toolbar { コンテンツ選択 / モード切替 / テストパターン / プリセット / 出力状態 }
///   }
struct EditorView: View {
    @Bindable var viewModel: MappingViewModel

    @State private var showContentPicker = false
    @State private var showPresetList = false
    @State private var showCropEditor = false
    @State private var showHelp = false
    @State private var showWelcome = false        // ツールバー「新規」
    @State private var showEffects = false         // エフェクト(F-FX-1)
    @State private var showControlSettings = false // 外部制御(F-CTRL-1/2)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    MeshCanvasView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    InspectorView(viewModel: viewModel)
                        .frame(width: 280)
                }
                Divider()
                TransportView(viewModel: viewModel)
            }
            .navigationTitle("CornerCast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                leadingToolbar
                modeToolbar
                trailingToolbar
            }
            .sheet(isPresented: $showContentPicker) {
                ContentPickerView(viewModel: viewModel)
            }
            .sheet(isPresented: $showPresetList) {
                PresetListView(viewModel: viewModel)
            }
            .sheet(isPresented: $showCropEditor) {
                CropEditorView(viewModel: viewModel)
            }
            .sheet(isPresented: $showHelp) {
                HelpView()
            }
            .sheet(isPresented: $showWelcome) {
                WelcomeView(viewModel: viewModel)
            }
            .sheet(isPresented: $showEffects) {
                EffectsView(viewModel: viewModel)
            }
            .sheet(isPresented: $showControlSettings) {
                ControlSettingsView()
            }
            // 初回起動時のユースケース選択(F-TPL-1)
            .fullScreenCover(isPresented: $viewModel.needsWelcome) {
                WelcomeView(viewModel: viewModel)
            }
        }
        // ブランドアクセント: 面の識別色(シアン)と揃え、Toggle/Slider/ボタンに一貫適用
        .tint(.cyan)
    }

    // MARK: ツールバー

    /// 左グループ: 新規 / コンテンツ / テストパターン / クロップ
    private var leadingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                showWelcome = true
            } label: {
                Label("新規", systemImage: "doc.badge.plus")
            }
            Button {
                showContentPicker = true
            } label: {
                Label("コンテンツ", systemImage: "photo.on.rectangle")
            }
            Button {
                viewModel.contentSource = .testPattern
            } label: {
                Label("テストパターン", systemImage: "grid")
            }
            Button {
                showCropEditor = true
            } label: {
                Label("クロップ", systemImage: "crop")
            }
        }
    }

    /// モード切替(RT / ベイク)
    private var modeToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("出力モード", selection: $viewModel.outputMode) {
                Text("リアルタイム").tag(MappingViewModel.OutputMode.realtime)
                Text("ベイク再生").tag(MappingViewModel.OutputMode.bakedPlayback)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
    }

    /// 右グループ: エフェクト / プリセット / 出力状態 +
    /// あまり使わない項目(外部制御 / ヘルプ)は「…」メニューに畳んで混雑を避ける。
    private var trailingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showEffects = true
            } label: {
                Label("エフェクト", systemImage: "wand.and.stars")
            }
            Button {
                showPresetList = true
            } label: {
                Label("プリセット", systemImage: "slider.horizontal.3")
            }
            Menu {
                Button {
                    showControlSettings = true
                } label: {
                    Label("外部制御", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button {
                    showHelp = true
                } label: {
                    Label("ヘルプ", systemImage: "questionmark.circle")
                }
            } label: {
                Label("その他", systemImage: "ellipsis.circle")
            }
            outputStatusIndicator
        }
    }

    /// 出力状態インジケータ(F-OUT-3): 緑●=接続中(解像度表示)、灰●=未接続
    private var outputStatusIndicator: some View {
        let state = viewModel.displayState
        return HStack(spacing: 6) {
            Circle()
                .fill(state.isConnected ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            if state.isConnected {
                Text("\(Int(state.resolution.width))×\(Int(state.resolution.height))")
                    .font(.caption)
                    .monospacedDigit()
            } else {
                Text("未接続")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
