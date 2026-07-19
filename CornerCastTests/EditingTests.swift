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
