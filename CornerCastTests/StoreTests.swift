import XCTest
import CoreGraphics
import Foundation
@testable import CornerCast

// TEST-1追補: 永続化層(PresetStore / BakeStore)のテスト。
// ENG-4の受け入れ条件「JSONのsurfacesがオブジェクト形状」をここで固定する。

// MARK: - プリセットJSONスキーマ形状

final class PresetSchemaTests: XCTestCase {

    /// §8スキーマの核心: surfaces はJSONオブジェクト(SE-0320によるString enumキー辞書)。
    /// これが配列になった場合、保存済みプリセットの互換性が壊れるため必ず検知する。
    func testSurfacesEncodesAsJSONObject() throws {
        let data = try JSONEncoder().encode(MappingPreset.makeDefault())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let surfaces = try XCTUnwrap(
            root["surfaces"] as? [String: Any],
            "surfacesはJSONオブジェクトであるべき(配列ならSE-0320が効いていない)"
        )
        XCTAssertEqual(Set(surfaces.keys), Set(Surface.allCases.map(\.rawValue)))
    }
}

// MARK: - PresetStore(実ファイルI/O)

final class PresetStoreRoundTripTests: XCTestCase {

    // 本番の Documents を使わないこと。既定のままだと実機/シミュレータで
    // 調整した lastUsed.json をテスト実行が実際に上書きしてしまう。
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CornerCastTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var store = PresetStore(rootDirectory: root)

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testSaveListDeleteRoundTrip() throws {
        var preset = MappingPreset.makeDefault()
        preset.id = UUID()
        preset.name = "テスト用-\(preset.id.uuidString.prefix(8))"
        preset.updatedAt = .now

        try store.save(preset)
        XCTAssertTrue(store.listPresets().contains { $0.id == preset.id },
                      "保存したプリセットが一覧に現れない")

        try store.delete(id: preset.id)
        XCTAssertFalse(store.listPresets().contains { $0.id == preset.id },
                       "削除したプリセットが一覧に残っている")
        // 冪等性: 存在しないIDの再削除でthrowしない
        XCTAssertNoThrow(try store.delete(id: preset.id))
    }

    func testLastUsedRoundTrip() {
        var preset = MappingPreset.makeDefault()
        preset.name = "lastUsed検証"
        store.saveLastUsed(preset)
        XCTAssertEqual(store.loadLastUsed()?.name, "lastUsed検証")
    }
}

// MARK: - BakeStore

final class BakeStoreTests: XCTestCase {

    /// isStale はプリセットのcalibrationFingerprint比較(F-BAKE-3)
    func testIsStaleComparesFingerprint() {
        let store = BakeStore()
        let preset = MappingPreset.makeDefault()
        let record = BakeRecord(
            id: UUID(),
            sourceFileName: "a.mp4",
            fileURL: URL(fileURLWithPath: "/tmp/a.mp4"),
            presetID: preset.id,
            calibrationFingerprint: preset.calibrationFingerprint,
            createdAt: .now,
            outputWidth: 1920,
            outputHeight: 1080
        )
        XCTAssertFalse(store.isStale(record, currentPreset: preset),
                       "同一fingerprintはstaleでないはず")

        var moved = preset
        moved.surfaces[.frontWall]?.quad.topLeft = CGPoint(x: 0.9, y: 0.9)
        XCTAssertTrue(store.isStale(record, currentPreset: moved),
                      "quadを動かしたらstaleになるはず")
    }
}
