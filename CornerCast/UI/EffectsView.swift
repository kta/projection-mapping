import SwiftUI

/// 出力エフェクト(F-FX-1)編集シート。
///
/// preset.effectSettings をスライダー4本(彩度/コントラスト/明度/色相)で編集する。
/// バインディングは preset を直接更新し、preset.didSet で自動保存される。
/// 各スライダーの操作開始時に beginGesture() を積んで1操作=1アンドゥ単位にする。
struct EffectsView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                slidersSection
                resetSection
            }
            .navigationTitle("エフェクト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    // MARK: スライダー4本

    @ViewBuilder private var slidersSection: some View {
        Section {
            effectSlider("彩度", binding: saturationBinding, range: 0...2,
                         format: .number.precision(.fractionLength(2)))
            effectSlider("コントラスト", binding: contrastBinding, range: 0.5...1.5,
                         format: .number.precision(.fractionLength(2)))
            effectSlider("明度", binding: brightnessBinding, range: -0.5...0.5,
                         format: .number.precision(.fractionLength(2)))
            effectSlider("色相", binding: hueBinding, range: -180...180,
                         format: .number.precision(.fractionLength(0)), unit: "°")
        } footer: {
            Text("投影とベイクの両方に反映されます。")
        }
    }

    private func effectSlider(_ title: String, binding: Binding<Double>,
                              range: ClosedRange<Double>,
                              format: FloatingPointFormatStyle<Double>,
                              unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(binding.wrappedValue, format: format)\(unit)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range) { editing in
                if editing { viewModel.beginGesture() }   // 1操作=1アンドゥ単位
            }
        }
    }

    // MARK: リセット

    @ViewBuilder private var resetSection: some View {
        Section {
            Button {
                viewModel.beginGesture()
                viewModel.preset.effectSettings = .neutral
            } label: {
                Label("リセット", systemImage: "arrow.counterclockwise")
            }
            .disabled(viewModel.preset.effectSettings.isNeutral)
        }
    }

    // MARK: - バインディング(preset を直接更新 → didSet で自動保存)

    private var saturationBinding: Binding<Double> {
        Binding(
            get: { viewModel.preset.effectSettings.saturation },
            set: { viewModel.preset.effectSettings.saturation = $0 }
        )
    }

    private var contrastBinding: Binding<Double> {
        Binding(
            get: { viewModel.preset.effectSettings.contrast },
            set: { viewModel.preset.effectSettings.contrast = $0 }
        )
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { viewModel.preset.effectSettings.brightness },
            set: { viewModel.preset.effectSettings.brightness = $0 }
        )
    }

    private var hueBinding: Binding<Double> {
        Binding(
            get: { viewModel.preset.effectSettings.hueDegrees },
            set: { viewModel.preset.effectSettings.hueDegrees = $0 }
        )
    }
}
