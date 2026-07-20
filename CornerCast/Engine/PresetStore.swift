import Foundation

/// プリセット永続化(F-PRESET-1〜3)。プロトコルはViewModelが依存するため変更禁止。
protocol PresetStoreProtocol: AnyObject {
    /// 前回終了時の状態(F-PRESET-2)。初回起動時はnil。
    func loadLastUsed() -> MappingPreset?
    func saveLastUsed(_ preset: MappingPreset)

    /// 名前付きプリセット(F-PRESET-1)
    func listPresets() -> [MappingPreset]
    func save(_ preset: MappingPreset) throws
    func delete(id: UUID) throws
}

/// 永続化に固有のエラー。破損JSONはnil/空配列で握りつぶす(N-REL-1)一方、
/// 明示的な保存/削除の失敗は呼び出し側(UI)へ通知したいため型で区別する。
enum PresetStoreError: LocalizedError {
    case documentsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "保存先ディレクトリにアクセスできません。"
        }
    }
}

/// Documents/Presets/ 以下にJSONで保存する実装。
/// - 名前付きプリセット: <UUID>.json
/// - 前回状態(自動保存): lastUsed.json(固定名)
final class PresetStore: PresetStoreProtocol {

    // MARK: 保存先の規約

    private static let presetsDirectoryName = "Presets"
    private static let lastUsedFileName = "lastUsed.json"

    private let fileManager: FileManager

    // JSONEncoder/Decoderは日付を.iso8601で扱う(要件§8のupdatedAtがISO8601形式のため)。
    // .sortedKeysはテストでの出力固定と差分の安定化のために付与している。
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// AppServicesは引数なしで生成するため、fileManagerはデフォルト引数で受ける。
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - PresetStoreProtocol

    func loadLastUsed() -> MappingPreset? {
        guard let url = lastUsedFileURL() else { return nil }
        return decodePreset(at: url)
    }

    func saveLastUsed(_ preset: MappingPreset) {
        // 自動保存はプロトコル上throwしない。失敗してもクラッシュさせず握りつぶす(N-REL-1)。
        guard let url = lastUsedFileURL() else { return }
        try? writePreset(preset, to: url)
    }

    func listPresets() -> [MappingPreset] {
        guard let dir = presetsDirectoryURL(),
              let urls = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        // lastUsed.json(自動保存)は名前付きプリセット一覧には含めない。
        // 破損ファイルはdecodePresetがnilを返すのでcompactMapで自然に除外される(N-REL-1)。
        return urls
            .filter { $0.pathExtension.lowercased() == "json"
                && $0.lastPathComponent != Self.lastUsedFileName }
            .compactMap { decodePreset(at: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ preset: MappingPreset) throws {
        guard let dir = presetsDirectoryURL() else {
            throw PresetStoreError.documentsDirectoryUnavailable
        }
        let url = dir.appendingPathComponent("\(preset.id.uuidString).json")
        try writePreset(preset, to: url)
    }

    func delete(id: UUID) throws {
        guard let dir = presetsDirectoryURL() else {
            throw PresetStoreError.documentsDirectoryUnavailable
        }
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        // 既に存在しない場合は成功扱い(冪等)。
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - 内部ヘルパ

    /// Documents/Presets/ のURL。無ければ作成する。取得不能時はnil。
    private func presetsDirectoryURL() -> URL? {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs.appendingPathComponent(Self.presetsDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func lastUsedFileURL() -> URL? {
        presetsDirectoryURL()?.appendingPathComponent(Self.lastUsedFileName)
    }

    private func writePreset(_ preset: MappingPreset, to url: URL) throws {
        let data = try encoder.encode(preset)
        // .atomicで書き込み途中のプロセス終了による破損を避ける。
        try data.write(to: url, options: .atomic)
    }

    /// 読み込み。破損JSON・読み取り不能・未対応スキーマはすべてnilを返しクラッシュしない(N-REL-1)。
    private func decodePreset(at url: URL) -> MappingPreset? {
        guard let data = try? Data(contentsOf: url),
              let preset = try? decoder.decode(MappingPreset.self, from: data) else {
            return nil
        }
        // 将来のschemaVersion(このビルドが知らない形式)は読み込みを拒否する。
        // 未知フィールドを既定値で埋めて誤動作するより、明示的に非対応とする方が安全。
        guard preset.schemaVersion <= MappingPreset.currentSchemaVersion else {
            return nil
        }
        return preset
    }
}
