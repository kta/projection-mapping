import Foundation

/// 外部制御(F-CTRL-1: OSC / F-CTRL-2: MIDI)の統括。
/// 設定(UserDefaults)に従いOSCServer/MIDIControllerを起動・停止し、
/// 受信メッセージをMainActor上でMappingViewModelへ適用する。
///
/// TODO(TASK CTRL-1 / 担当: control agent):
/// - UserDefaultsキー: "control.osc.enabled"(Bool) / "control.osc.port"(Int, 既定8000) /
///   "control.midi.enabled"(Bool)
/// - start(): 設定を読み、有効なものを起動。stop(): 全停止。冪等にすること。
/// - applySettings(oscEnabled:oscPort:midiEnabled:): 保存して再起動。
/// - 受信→ViewModel適用はすべて `Task { @MainActor in ... }` 経由(スレッド安全)。
/// - OSCアドレス空間はdocs/06_プロ機能設計.md §5を厳守(テストと共有契約)。
@MainActor
final class ControlHub {
    private let viewModel: MappingViewModel
    private var oscServer: OSCServer?
    private var midiController: MIDIController?

    private(set) var isRunning = false

    init(viewModel: MappingViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        // TODO: CTRL-1
    }

    func stop() {
        // TODO: CTRL-1
    }
}

/// OSC受信サーバ(F-CTRL-1)。UDPで待ち受け、OSCパケットをパースする。
///
/// TODO(TASK CTRL-1):
/// - Network.framework(NWListener, .udp)で指定ポートを待ち受け。
/// - パース結果はOSCMessage(下記・純関数)を使う。
/// - ハンドラはバックグラウンドスレッドから呼ばれる旨をドキュメント化。
final class OSCServer {
    var messageHandler: ((OSCMessage) -> Void)?

    init(port: UInt16) {
        // TODO: CTRL-1
    }

    func start() throws {
        // TODO: CTRL-1
    }

    func stop() {
        // TODO: CTRL-1
    }
}

/// OSCメッセージ(パース済み)。パースは**純関数**にしてユニットテスト可能にする(契約)。
/// 対応型タグ: f(float32) / i(int32→Floatへ変換) のみ。他はスキップしてよい。
struct OSCMessage: Equatable {
    var address: String
    var floats: [Float]

    /// OSCパケット(単一メッセージ)をパースする。バンドル(#bundle)は未対応でnil。
    /// TODO(TASK CTRL-1): 実装。OSC 1.0仕様: アドレス(null終端・4バイト境界パディング)、
    /// ","で始まる型タグ列(同パディング)、引数(ビッグエンディアン)。
    static func parse(_ data: Data) -> OSCMessage? {
        nil // TODO: CTRL-1
    }
}

/// MIDI受信(F-CTRL-2)。固定マッピング(docs/06 §5.2)でViewModelを操作する。
///
/// TODO(TASK CTRL-1):
/// - CoreMIDIで入力を受ける。APIシグネチャに確信が持てない場合は実装せず質問すること
///   (存在しないAPIの発明は差し戻し)。
final class MIDIController {
    var eventHandler: ((MIDIControlEvent) -> Void)?

    func start() throws {
        // TODO: CTRL-1
    }

    func stop() {
        // TODO: CTRL-1
    }
}

/// MIDI由来の抽象イベント(テスト可能な中間表現)
enum MIDIControlEvent: Equatable {
    case controlChange(number: UInt8, value: UInt8)
    case noteOn(note: UInt8)
}
