import SwiftUI

/// 外部制御設定(F-CTRL-1/2)シート。OSC/MIDIの有効化とポート設定。
///
/// 実装(TASK CTRL-1):
/// - OSC: 有効Toggle+ポートTextField(1024-65535検証)。適用でControlHub再起動。
/// - MIDI: 有効Toggle(受信は現状スタブ)。
/// - OSCアドレス一覧(docs/06 §5.1)とMIDI固定マッピング(§5.2)をヘルプとして表示。
/// - 状態はAppServices.shared.controlHub経由。
struct ControlSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var oscEnabled = false
    @State private var portText = "\(ControlHub.defaultPort)"
    @State private var midiEnabled = false
    @State private var isRunning = false

    /// 検証済みポート(1024-65535)。不正なら nil。
    private var parsedPort: Int? {
        guard let p = Int(portText), ControlHub.portRange.contains(p) else { return nil }
        return p
    }

    var body: some View {
        NavigationStack {
            Form {
                oscSection
                midiSection
                statusSection
                oscAddressHelpSection
                midiMappingHelpSection
            }
            .navigationTitle("外部制御")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") { apply() }
                        .disabled(parsedPort == nil)
                }
            }
            .onAppear(perform: syncFromHub)
        }
    }

    // MARK: - セクション

    private var oscSection: some View {
        Section("OSC (F-CTRL-1)") {
            Toggle("OSCを有効化", isOn: $oscEnabled)
            HStack {
                Text("ポート")
                Spacer()
                TextField("\(ControlHub.defaultPort)", text: $portText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 96)
            }
            if parsedPort == nil {
                Label("ポートは \(ControlHub.portRange.lowerBound)〜\(ControlHub.portRange.upperBound) の数値で指定してください",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("UDPで待ち受け、単一OSCメッセージ(型タグ f / i)を受信します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var midiSection: some View {
        Section("MIDI (F-CTRL-2)") {
            Toggle("MIDIを有効化", isOn: $midiEnabled)
            Text("MIDI受信は現在未実装です(将来対応)。有効化しても本バージョンでは動作しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        Section("状態") {
            HStack(spacing: 8) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(isRunning ? "OSC受信中" : "停止中")
                Spacer()
                Button("再読み込み", action: syncFromHub)
                    .font(.caption)
            }
        }
    }

    private var oscAddressHelpSection: some View {
        Section("OSCアドレス一覧 (docs/06 §5.1)") {
            helpRow("/cc/corner/<leftWall|frontWall|floor>/<tl|tr|br|bl>",
                    "ff (x, y 0-1)", "該当頂点を移動")
            helpRow("/cc/brightness/<surface>", "f (0.25-2)", "面の明るさ")
            helpRow("/cc/gamma/<surface>", "f (0.25-4)", "面のガンマ")
            helpRow("/cc/feather/<surface>", "f (0-0.3)", "面のフェザー")
            helpRow("/cc/play", "なし", "再生")
            helpRow("/cc/pause", "なし", "一時停止")
            helpRow("/cc/mode", "i (0=realtime, 1=baked)", "出力モード切替")
        }
    }

    private var midiMappingHelpSection: some View {
        Section("MIDIマッピング (docs/06 §5.2)") {
            helpRow("CC 20 / 21", "", "選択中頂点の X / Y (0-127→0-1)")
            helpRow("CC 22 / 23", "", "選択中面の明るさ / ガンマ")
            helpRow("Note On 60 / 61", "", "再生 / 一時停止")
        }
    }

    // MARK: - 部品

    @ViewBuilder
    private func helpRow(_ address: String, _ args: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(address)
                .font(.system(.caption, design: .monospaced))
            Text(args.isEmpty ? desc : "\(args) — \(desc)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - アクション

    private func syncFromHub() {
        let hub = AppServices.shared.controlHub
        oscEnabled = hub.oscEnabled
        portText = "\(hub.oscPort)"
        midiEnabled = hub.midiEnabled
        isRunning = hub.isRunning
    }

    private func apply() {
        guard let port = parsedPort else { return }
        let hub = AppServices.shared.controlHub
        hub.applySettings(oscEnabled: oscEnabled, oscPort: port, midiEnabled: midiEnabled)
        isRunning = hub.isRunning
    }
}
