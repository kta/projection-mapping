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

/// TODO(TASK ENG-4 / 担当: persistence agent):
/// - 保存先: FileManager.default.urls(for: .documentDirectory, ...)/Presets/ 以下に
///   <UUID>.json、lastUsedは lastUsed.json という固定名で保存する。
/// - JSONEncoder/Decoderは .iso8601 の日付戦略・.prettyPrinted を使用。
/// - [Surface: SurfaceConfig] のエンコード形状に注意: Swift 5.6+(SE-0320)では
///   String-backed enumキーの辞書はJSONオブジェクトとしてエンコードされる(それ以前は配列)。
///   本プロジェクトはSwift 5.9なのでオブジェクトになるはずだが、要件§8のスキーマ
///   (surfacesがオブジェクト)と一致することを必ずテストで固定すること(TEST-1と連携)。
/// - 読み込み失敗(破損JSON)はnil/空配列を返しクラッシュしない(N-REL-1)。
/// - schemaVersionが将来値の場合は読み込みを拒否してnilを返す。
final class PresetStore: PresetStoreProtocol {
    func loadLastUsed() -> MappingPreset? {
        nil // TODO: ENG-4
    }

    func saveLastUsed(_ preset: MappingPreset) {
        // TODO: ENG-4
    }

    func listPresets() -> [MappingPreset] {
        [] // TODO: ENG-4
    }

    func save(_ preset: MappingPreset) throws {
        // TODO: ENG-4
    }

    func delete(id: UUID) throws {
        // TODO: ENG-4
    }
}
