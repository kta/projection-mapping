import XCTest
import CoreGraphics
@testable import CornerCast

// TEST-1: MappingViewModel(@MainActor)のユニットテスト。
// PresetStoreProtocol のテスト用モックはここに定義する(本体側ファイルへの追加は禁止)。

/// テスト用のインメモリ PresetStore。ファイルI/Oを持たない。
final class InMemoryPresetStore: PresetStoreProtocol {
    var lastUsed: MappingPreset?
    private(set) var saved: [UUID: MappingPreset] = [:]

    init(lastUsed: MappingPreset? = nil) {
        self.lastUsed = lastUsed
    }

    func loadLastUsed() -> MappingPreset? { lastUsed }
    func saveLastUsed(_ preset: MappingPreset) { lastUsed = preset }
    func listPresets() -> [MappingPreset] { Array(saved.values) }
    func save(_ preset: MappingPreset) throws { saved[preset.id] = preset }
    func delete(id: UUID) throws { saved[id] = nil }
}

@MainActor
final class ViewModelTests: XCTestCase {

    private func makeVM() -> MappingViewModel {
        MappingViewModel(presetStore: InMemoryPresetStore())
    }

    // MARK: init

    /// loadLastUsed が nil なら makeDefault が使われる
    func testInitFallsBackToDefault() {
        let vm = MappingViewModel(presetStore: InMemoryPresetStore(lastUsed: nil))
        XCTAssertEqual(vm.preset.surfaces.count, 3)
        XCTAssertEqual(vm.preset.links.count, 4)
    }

    /// loadLastUsed があればそれを採用する
    func testInitUsesLastUsed() {
        var stored = MappingPreset.makeDefault()
        stored.name = "前回の状態"
        let vm = MappingViewModel(presetStore: InMemoryPresetStore(lastUsed: stored))
        XCTAssertEqual(vm.preset.name, "前回の状態")
    }

    // MARK: move — クランプ

    func testMoveClampsOutOfRange() {
        let vm = makeVM()
        vm.move(corner: .topLeft, of: .frontWall, to: CGPoint(x: -1, y: -1))
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, CGPoint(x: 0, y: 0))

        vm.move(corner: .bottomRight, of: .frontWall, to: CGPoint(x: 2, y: 3))
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.bottomRight, CGPoint(x: 1, y: 1))
    }

    /// ロック中は move が無視される(F-UI-6)
    func testMoveIgnoredWhenLocked() {
        let vm = makeVM()
        let before = vm.preset.surfaces[.frontWall]?.quad.topLeft
        vm.isEditLocked = true
        vm.move(corner: .topLeft, of: .frontWall, to: CGPoint(x: 0.9, y: 0.9))
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, before)
    }

    // MARK: move — リンク追従(F-WARP-5)

    /// リンク有効時: a を動かすと相手頂点(b)が追従する
    func testMoveFollowsEnabledLink() {
        let vm = makeVM()
        // 既定リンク[0]: a=leftWall.topRight, b=frontWall.topLeft
        let link = vm.preset.links[0]
        vm.setLink(id: link.id, enabled: true)

        let target = CGPoint(x: 0.42, y: 0.15)
        vm.move(corner: .topRight, of: .leftWall, to: target)

        XCTAssertEqual(vm.preset.surfaces[.leftWall]?.quad.topRight, target)
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, target,
                       "リンク有効時は相手頂点が追従するはず")
    }

    /// b 側を動かしても a 側が追従する(双方向)
    func testMoveFollowsEnabledLinkReverse() {
        let vm = makeVM()
        let link = vm.preset.links[0] // a=leftWall.topRight, b=frontWall.topLeft
        vm.setLink(id: link.id, enabled: true)

        let target = CGPoint(x: 0.33, y: 0.22)
        vm.move(corner: .topLeft, of: .frontWall, to: target)

        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, target)
        XCTAssertEqual(vm.preset.surfaces[.leftWall]?.quad.topRight, target)
    }

    /// リンク無効時: 相手頂点は追従しない
    func testMoveDoesNotFollowDisabledLink() {
        let vm = makeVM()
        // 既定はリンク無効
        let before = vm.preset.surfaces[.frontWall]?.quad.topLeft
        vm.move(corner: .topRight, of: .leftWall, to: CGPoint(x: 0.42, y: 0.15))
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, before,
                       "リンク無効時は相手頂点は動かないはず")
    }

    /// setLink 有効化時に b 側が a 側へ吸着する
    func testSetLinkSnapsBToA() {
        let vm = makeVM()
        let link = vm.preset.links[0] // a=leftWall.topRight, b=frontWall.topLeft
        let aPos = vm.preset.surfaces[.leftWall]?.quad.topRight
        vm.setLink(id: link.id, enabled: true)
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, aPos)
    }

    // MARK: undo(F-UI-4)

    /// beginGesture → move → undo で元に戻る
    func testUndoRestoresAfterMove() {
        let vm = makeVM()
        let original = vm.preset.surfaces[.frontWall]?.quad.topLeft

        vm.beginGesture()
        vm.move(corner: .topLeft, of: .frontWall, to: CGPoint(x: 0.9, y: 0.9))
        XCTAssertNotEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, original)

        vm.undo()
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, original)
        XCTAssertFalse(vm.canUndo)
    }

    /// 空スタックで undo してもクラッシュしない/no-op
    func testUndoOnEmptyStackIsNoOp() {
        let vm = makeVM()
        XCTAssertFalse(vm.canUndo)
        let before = vm.preset
        vm.undo()
        XCTAssertEqual(vm.preset, before)
    }

    /// undo 上限 20: 25回 push しても最大20回しか戻せない
    func testUndoLimitedTo20() {
        let vm = makeVM()
        for _ in 0..<25 {
            vm.beginGesture()
        }
        var count = 0
        while vm.canUndo {
            vm.undo()
            count += 1
        }
        XCTAssertEqual(count, 20, "アンドゥ上限は20のはず")
    }

    // MARK: resetSurface

    /// resetSurface: 対象面のみ既定値に戻る
    func testResetSurfaceOnlyAffectsTarget() {
        let vm = makeVM()
        let defaultFront = MappingPreset.makeDefault().surfaces[.frontWall]
        let defaultLeft = MappingPreset.makeDefault().surfaces[.leftWall]

        // 両面を変更
        vm.move(corner: .topLeft, of: .frontWall, to: CGPoint(x: 0.9, y: 0.9))
        vm.move(corner: .topLeft, of: .leftWall, to: CGPoint(x: 0.8, y: 0.8))

        vm.resetSurface(.frontWall)

        // frontWall は既定へ、leftWall は変更されたまま
        XCTAssertEqual(vm.preset.surfaces[.frontWall], defaultFront)
        XCTAssertNotEqual(vm.preset.surfaces[.leftWall], defaultLeft)
        XCTAssertEqual(vm.preset.surfaces[.leftWall]?.quad.topLeft, CGPoint(x: 0.8, y: 0.8))
    }

    /// resetSurface はアンドゥ可能
    func testResetSurfacePushesUndo() {
        let vm = makeVM()
        vm.move(corner: .topLeft, of: .frontWall, to: CGPoint(x: 0.9, y: 0.9))
        let modified = vm.preset.surfaces[.frontWall]?.quad.topLeft

        vm.resetSurface(.frontWall)
        XCTAssertTrue(vm.canUndo)
        vm.undo()
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.quad.topLeft, modified)
    }
}
