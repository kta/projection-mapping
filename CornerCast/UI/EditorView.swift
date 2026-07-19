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
                // コンテンツ選択 / テストパターン
                ToolbarItemGroup(placement: .topBarLeading) {
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
                // モード切替(RT / ベイク)
                ToolbarItem(placement: .principal) {
                    Picker("出力モード", selection: $viewModel.outputMode) {
                        Text("リアルタイム").tag(MappingViewModel.OutputMode.realtime)
                        Text("ベイク再生").tag(MappingViewModel.OutputMode.bakedPlayback)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                // プリセット / 出力状態
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showPresetList = true
                    } label: {
                        Label("プリセット", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        showHelp = true
                    } label: {
                        Label("ヘルプ", systemImage: "questionmark.circle")
                    }
                    outputStatusIndicator
                }
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
