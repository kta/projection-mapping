import XCTest
import CoreGraphics
@testable import CornerCast

/// v1.2追加API(面全体移動 translate / クロップ編集 setCrop)のテスト。
/// InMemoryPresetStore は ViewModelTests.swift で定義済みのものを使う。
@MainActor
final class EditingTests: XCTestCase {

    private func makeVM() -> MappingViewModel {
        MappingViewModel(presetStore: InMemoryPresetStore())
    }

    // MARK: translate(F-UI-7)

    /// 全頂点がdeltaぶん平行移動する
    func testTranslateMovesAllCorners() {
        let vm = makeVM()
        guard let base = vm.preset.surfaces[.frontWall]?.quad else {
            return XCTFail("frontWallが存在しない")
        }
        let delta = CGPoint(x: 0.05, y: -0.03)
        vm.translate(surface: .frontWall, by: delta, from: base)

        for corner in Quad.Corner.allCases {
            let p = vm.preset.surfaces[.frontWall]!.quad[corner]
            XCTAssertEqual(p.x, base[corner].x + delta.x, accuracy: 1e-9)
            XCTAssertEqual(p.y, base[corner].y + delta.y, accuracy: 1e-9)
        }
    }

    /// 大きなdeltaでも全頂点が0-1に収まり、形状(頂点間の相対位置)が保たれる
    func testTranslateClampsPreservingShape() {
        let vm = makeVM()
        guard let base = vm.preset.surfaces[.frontWall]?.quad else {
            return XCTFail("frontWallが存在しない")
        }
        let baseWidth = base.topRight.x - base.topLeft.x

        vm.translate(surface: .frontWall, by: CGPoint(x: 10, y: 10), from: base)

        let quad = vm.preset.surfaces[.frontWall]!.quad
        for corner in Quad.Corner.allCases {
            let p = quad[corner]
            XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y),
                          "クランプ後も頂点は0-1内であるべき")
        }
        // 個別クランプではなくdelta事前クランプなので、形状は歪まない
        XCTAssertEqual(quad.topRight.x - quad.topLeft.x, baseWidth, accuracy: 1e-9,
                       "面の幅が変わっている = 形状が歪んでいる")
        // 右端に張り付いているはず
        XCTAssertEqual(quad.topRight.x, 1.0, accuracy: 1e-9)
    }

    /// 編集ロック中は動かない
    func testTranslateIgnoredWhenLocked() {
        let vm = makeVM()
        guard let base = vm.preset.surfaces[.frontWall]?.quad else {
            return XCTFail("frontWallが存在しない")
        }
        vm.isEditLocked = true
        vm.translate(surface: .frontWall, by: CGPoint(x: 0.1, y: 0.1), from: base)
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad, base)
    }

    // MARK: setCrop(F-CROP-2/3)

    /// 通常の矩形はそのまま反映される
    func testSetCropAppliesRect() {
        let vm = makeVM()
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        vm.setCrop(rect, for: .leftWall)
        XCTAssertEqual(vm.preset.surfaces[.leftWall]?.crop, rect)
    }

    /// 範囲外の原点・過大サイズはクランプされる
    func testSetCropClampsOriginAndSize() {
        let vm = makeVM()
        vm.setCrop(CGRect(x: 0.9, y: -0.5, width: 5, height: 5), for: .leftWall)
        let crop = vm.preset.surfaces[.leftWall]!.crop
        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 最小サイズ(5%)を下回らない
    func testSetCropEnforcesMinimumSize() {
        let vm = makeVM()
        vm.setCrop(CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001), for: .floor)
        let crop = vm.preset.surfaces[.floor]!.crop
        XCTAssertEqual(crop.width, 0.05, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 0.05, accuracy: 1e-9)
    }

    /// 編集ロック中は変更されない
    func testSetCropIgnoredWhenLocked() {
        let vm = makeVM()
        let before = vm.preset.surfaces[.floor]?.crop
        vm.isEditLocked = true
        vm.setCrop(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), for: .floor)
        XCTAssertEqual(vm.preset.surfaces[.floor]?.crop, before)
    }

    /// クロップ変更はcalibrationFingerprintに反映される(ベイク陳腐化検知と連動)
    func testSetCropChangesFingerprint() {
        let vm = makeVM()
        let before = vm.preset.calibrationFingerprint
        vm.setCrop(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), for: .frontWall)
        XCTAssertNotEqual(vm.preset.calibrationFingerprint, before)
    }
}

/// 自由面(F-FREE-1)とフェザー(F-WARP-7)のテスト。
@MainActor
final class ExtraSurfaceTests: XCTestCase {

    private func makeVM() -> MappingViewModel {
        MappingViewModel(presetStore: InMemoryPresetStore())
    }

    /// 追加→選択→削除の基本サイクル
    func testAddSelectRemoveExtra() {
        let vm = makeVM()
        XCTAssertTrue(vm.preset.extras.isEmpty)

        vm.addExtraSurface()
        XCTAssertEqual(vm.preset.extras.count, 1)
        XCTAssertEqual(vm.selectedExtraID, vm.preset.extras.first?.id)
        XCTAssertNil(vm.selectedSurface, "自由面選択時はコーナー面の選択が外れるはず")

        let id = vm.preset.extras.first!.id
        vm.removeExtraSurface(id: id)
        XCTAssertTrue(vm.preset.extras.isEmpty)
        XCTAssertNil(vm.selectedExtraID)
    }

    /// 追加/削除はアンドゥで戻せる
    func testAddExtraIsUndoable() {
        let vm = makeVM()
        vm.addExtraSurface()
        XCTAssertEqual(vm.preset.extras.count, 1)
        vm.undo()
        XCTAssertTrue(vm.preset.extras.isEmpty)
    }

    /// 自由面の頂点移動はクランプされる
    func testMoveExtraClamps() {
        let vm = makeVM()
        vm.addExtraSurface()
        let id = vm.preset.extras.first!.id
        vm.moveExtra(corner: .topLeft, id: id, to: CGPoint(x: -5, y: 5))
        XCTAssertEqual(vm.preset.extras.first?.config.quad.topLeft, CGPoint(x: 0, y: 1))
    }

    /// 自由面のクロップも最小サイズ・範囲クランプが効く
    func testSetExtraCropClamps() {
        let vm = makeVM()
        vm.addExtraSurface()
        let id = vm.preset.extras.first!.id
        vm.setExtraCrop(CGRect(x: 2, y: 2, width: 0.001, height: 0.001), id: id)
        let crop = vm.preset.extras.first!.config.crop
        XCTAssertEqual(crop.width, 0.05, accuracy: 1e-9)
        XCTAssertEqual(crop.maxX, 1.0, accuracy: 1e-9)
    }

    /// 自由面の追加・フェザー変更はfingerprintに反映される(ベイク陳腐化検知)
    func testExtrasAndFeatherAffectFingerprint() {
        let vm = makeVM()
        let base = vm.preset.calibrationFingerprint

        vm.addExtraSurface()
        let withExtra = vm.preset.calibrationFingerprint
        XCTAssertNotEqual(base, withExtra)

        vm.preset.surfaces[.frontWall]?.feather = 0.15
        XCTAssertNotEqual(withExtra, vm.preset.calibrationFingerprint)
    }

    /// extras未指定の旧JSONもデコードできる(後方互換)
    func testDecodingLegacyJSONWithoutExtras() throws {
        let legacy = MappingPreset.makeDefault()
        // extraSurfaces/featherキーを含まないJSONを合成: 旧スキーマを再現するため
        // いったんエンコードしてキーを削除する
        let data = try JSONEncoder().encode(legacy)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root.removeValue(forKey: "extraSurfaces")
        if var surfaces = root["surfaces"] as? [String: [String: Any]] {
            for key in surfaces.keys { surfaces[key]?.removeValue(forKey: "feather") }
            root["surfaces"] = surfaces
        }
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(MappingPreset.self, from: legacyData)
        XCTAssertTrue(decoded.extras.isEmpty)
        XCTAssertEqual(decoded.surfaces[.frontWall]?.feather ?? -1, 0.0, accuracy: 1e-9)
    }
}
