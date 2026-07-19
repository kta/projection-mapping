import XCTest
import CoreImage
import CoreGraphics
@testable import CornerCast

// TASK PRO-T: v1.4プロ機能(メッシュワープ / マスク / エフェクト / テンプレート / OSC)のテスト。
// 既存テストの流儀に合わせ、実装済みコア(Models/FrameComposer/ViewModel)の仕様を固定し、
// OSCパース(ControlHub — 並行実装中)は §5.1 の共有契約を直接検証する。
// InMemoryPresetStore は ViewModelTests.swift 定義のものを使う。

// MARK: - WarpMesh(F-MESH-1)

final class WarpMeshTests: XCTestCase {

    private func assertPoint(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-9,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    /// fromQuad: 軸平行quadは等間隔の格子になり、点数=rows*cols、四隅がquadの四隅に一致する
    func testFromQuadAxisAlignedIsEvenGrid() {
        let q = Quad(rect: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8))
        let mesh = WarpMesh.fromQuad(q, rows: 4, cols: 4)

        // 点数 = rows * cols
        XCTAssertEqual(mesh.rows, 4)
        XCTAssertEqual(mesh.cols, 4)
        XCTAssertEqual(mesh.points.count, 16)

        // 四隅がquadの四隅に一致
        assertPoint(mesh.point(row: 0, col: 0), q.topLeft)
        assertPoint(mesh.point(row: 0, col: 3), q.topRight)
        assertPoint(mesh.point(row: 3, col: 3), q.bottomRight)
        assertPoint(mesh.point(row: 3, col: 0), q.bottomLeft)

        // 軸平行quadでは x は col のみ・y は row のみに依存し、等間隔で並ぶ
        let dx: CGFloat = 0.6 / 3.0   // cols-1 = 3 分割
        let dy: CGFloat = 0.8 / 3.0   // rows-1 = 3 分割
        for r in 0..<4 {
            for c in 0..<4 {
                let p = mesh.point(row: r, col: c)
                XCTAssertEqual(p.x, 0.2 + CGFloat(c) * dx, accuracy: 1e-9,
                               "(\(r),\(c)) のx間隔が等間隔でない")
                XCTAssertEqual(p.y, 0.1 + CGFloat(r) * dy, accuracy: 1e-9,
                               "(\(r),\(c)) のy間隔が等間隔でない")
            }
        }
    }

    /// 非既定の rows/cols でも点数が rows*cols になる
    func testFromQuadHonorsCustomDimensions() {
        let q = Quad(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let mesh = WarpMesh.fromQuad(q, rows: 3, cols: 5)
        XCTAssertEqual(mesh.rows, 3)
        XCTAssertEqual(mesh.cols, 5)
        XCTAssertEqual(mesh.points.count, 15)
    }
}

// MARK: - calibrationFingerprint(F-BAKE-3): プロ機能フィールド

final class ProFingerprintTests: XCTestCase {

    /// メッシュ有効化・メッシュ点移動でfingerprintが変化する
    func testMeshAffectsFingerprint() {
        let base = MappingPreset.makeDefault()

        var withMesh = base
        withMesh.surfaces[.frontWall]?.mesh =
            WarpMesh.fromQuad(base.surfaces[.frontWall]!.quad, rows: 4, cols: 4)
        XCTAssertNotEqual(base.calibrationFingerprint, withMesh.calibrationFingerprint,
                          "メッシュ有効化でfingerprintが変わるはず")

        var movedPoint = withMesh
        if var mesh = movedPoint.surfaces[.frontWall]?.mesh {
            mesh.points[5].x += 0.1
            movedPoint.surfaces[.frontWall]?.mesh = mesh
        }
        XCTAssertNotEqual(withMesh.calibrationFingerprint, movedPoint.calibrationFingerprint,
                          "メッシュ点移動でfingerprintが変わるはず")
    }

    /// マスク追加でfingerprintが変化する
    func testMaskAffectsFingerprint() {
        let base = MappingPreset.makeDefault()
        var withMask = base
        withMask.maskShapes = [MaskShape(quad: Quad(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))]
        XCTAssertNotEqual(base.calibrationFingerprint, withMask.calibrationFingerprint)
    }

    /// エフェクト変更でfingerprintが変化し、ニュートラルなエフェクトでは不変
    func testEffectAffectsFingerprintButNeutralDoesNot() {
        let base = MappingPreset.makeDefault()

        var withFx = base
        withFx.effectSettings = EffectSettings(saturation: 1.5, contrast: 1.2,
                                               brightness: 0.1, hueDegrees: 45)
        XCTAssertNotEqual(base.calibrationFingerprint, withFx.calibrationFingerprint,
                          "エフェクト変更でfingerprintが変わるはず")

        var neutral = base
        neutral.effectSettings = .neutral
        XCTAssertEqual(base.calibrationFingerprint, neutral.calibrationFingerprint,
                       "ニュートラルなエフェクトではfingerprintは不変のはず")
    }
}

// MARK: - FrameComposer(F-MESH-1 / F-MASK-1 / F-FX-1)

// CIImage のピクセル検証は CIContext 依存のため、extent 検証とレシピ構築が
// クラッシュしないことの確認に留める(FrameComposerTests.swift と同方針)。
final class ProFrameComposerTests: XCTestCase {

    private let composer = FrameComposer()
    private let canvas = CGSize(width: 1920, height: 1080)

    private func makeFrame(width: CGFloat = 1280, height: CGFloat = 720) -> CIImage {
        CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// メッシュ付き(4x4)compose: extentがキャンバスに一致・クラッシュしない
    func testComposeWithMeshMatchesCanvas() {
        var preset = MappingPreset.makeDefault()
        // 排他アクセス違反を避けるためquadをローカルへ退避してから代入する
        let frontQuad = preset.surfaces[.frontWall]!.quad
        preset.surfaces[.frontWall]?.mesh = WarpMesh.fromQuad(frontQuad, rows: 4, cols: 4)
        let params = RenderParameters(canvasSize: canvas, preset: preset)

        let result = composer.compose(frame: makeFrame(), params: params)
        XCTAssertEqual(result.extent, CGRect(origin: .zero, size: canvas))
    }

    /// マスク付き compose も extent がキャンバスに一致する
    func testComposeWithMaskMatchesCanvas() {
        var preset = MappingPreset.makeDefault()
        preset.maskShapes = [
            MaskShape(quad: Quad(rect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)))
        ]
        let params = RenderParameters(canvasSize: canvas, preset: preset)

        let result = composer.compose(frame: makeFrame(), params: params)
        XCTAssertEqual(result.extent, CGRect(origin: .zero, size: canvas))
    }

    /// エフェクト付き compose も extent がキャンバスに一致する
    func testComposeWithEffectsMatchesCanvas() {
        var preset = MappingPreset.makeDefault()
        preset.effectSettings = EffectSettings(saturation: 1.5, contrast: 1.2,
                                               brightness: 0.1, hueDegrees: 45)
        let params = RenderParameters(canvasSize: canvas, preset: preset)

        let result = composer.compose(frame: makeFrame(), params: params)
        XCTAssertEqual(result.extent, CGRect(origin: .zero, size: canvas))
    }

    /// メッシュ+マスク+エフェクトを全部載せてもクラッシュせず extent が保たれる
    func testComposeWithAllProFeaturesMatchesCanvas() {
        var preset = MappingPreset.makeDefault()
        let leftQuad = preset.surfaces[.leftWall]!.quad
        preset.surfaces[.leftWall]?.mesh = WarpMesh.fromQuad(leftQuad, rows: 4, cols: 4)
        preset.maskShapes = [
            MaskShape(quad: Quad(rect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)))
        ]
        preset.effectSettings = EffectSettings(saturation: 0.5, contrast: 1.4,
                                               brightness: -0.2, hueDegrees: -90)
        let params = RenderParameters(canvasSize: canvas, preset: preset)

        let result = composer.compose(frame: makeFrame(), params: params)
        XCTAssertEqual(result.extent, CGRect(origin: .zero, size: canvas))
    }
}

// MARK: - MappingViewModel(mesh / mask / template API)

@MainActor
final class ProViewModelTests: XCTestCase {

    private func makeVM() -> MappingViewModel {
        MappingViewModel(presetStore: InMemoryPresetStore())
    }

    // MARK: メッシュ(F-MESH-1)

    /// setMeshEnabled(true)で4x4メッシュが入り、falseでnilに戻る
    func testSetMeshEnabledTogglesMesh() {
        let vm = makeVM()
        XCTAssertNil(vm.preset.surfaces[.frontWall]?.mesh)

        vm.setMeshEnabled(true, for: .frontWall)
        let mesh = vm.preset.surfaces[.frontWall]?.mesh
        XCTAssertNotNil(mesh, "有効化でメッシュが入るはず")
        XCTAssertEqual(mesh?.rows, 4)
        XCTAssertEqual(mesh?.cols, 4)
        XCTAssertEqual(mesh?.points.count, 16)

        vm.setMeshEnabled(false, for: .frontWall)
        XCTAssertNil(vm.preset.surfaces[.frontWall]?.mesh, "無効化でnilに戻るはず")
    }

    /// moveMeshPoint は 0-1 にクランプする
    func testMoveMeshPointClamps() {
        let vm = makeVM()
        vm.setMeshEnabled(true, for: .frontWall)
        vm.moveMeshPoint(surface: .frontWall, index: 0, to: CGPoint(x: -5, y: 5))
        XCTAssertEqual(vm.preset.surfaces[.frontWall]?.mesh?.points[0], CGPoint(x: 0, y: 1))
    }

    // MARK: マスク(F-MASK-1)

    /// addMask で selectedMaskID が設定され、面選択が外れる
    func testAddMaskSelectsAndClearsSurface() {
        let vm = makeVM()
        XCTAssertTrue(vm.preset.maskShapes.isEmpty)

        vm.addMask()
        XCTAssertEqual(vm.preset.maskShapes.count, 1)
        XCTAssertEqual(vm.selectedMaskID, vm.preset.maskShapes.first?.id)
        XCTAssertNil(vm.selectedSurface, "マスク選択時はコーナー面選択が外れるはず")
        XCTAssertNil(vm.selectedExtraID)
    }

    /// removeMask で選択が解除される
    func testRemoveMaskClearsSelection() {
        let vm = makeVM()
        vm.addMask()
        let id = vm.preset.maskShapes.first!.id
        vm.removeMask(id: id)
        XCTAssertTrue(vm.preset.maskShapes.isEmpty)
        XCTAssertNil(vm.selectedMaskID)
    }

    /// translateMask: 大きなdeltaでも全頂点が0-1内・形状(幅)を保つ(EditingTests.translate系に準拠)
    func testTranslateMaskClampsPreservingShape() {
        let vm = makeVM()
        vm.addMask()
        let id = vm.preset.maskShapes.first!.id
        let base = vm.preset.maskShapes.first!.quad
        let baseWidth = base.topRight.x - base.topLeft.x

        vm.translateMask(id: id, by: CGPoint(x: 10, y: 10), from: base)

        let quad = vm.preset.maskShapes.first!.quad
        for corner in Quad.Corner.allCases {
            let p = quad[corner]
            XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y),
                          "クランプ後も頂点は0-1内であるべき")
        }
        XCTAssertEqual(quad.topRight.x - quad.topLeft.x, baseWidth, accuracy: 1e-9,
                       "マスクの幅が変わっている = 形状が歪んでいる")
        XCTAssertEqual(quad.topRight.x, 1.0, accuracy: 1e-9, "右端に張り付いているはず")
    }

    // MARK: テンプレート(F-TPL-1)

    /// apply(.freeform): surfacesが空・extras1枚・自由面が選択される
    func testApplyFreeformTemplate() {
        let vm = makeVM()
        vm.apply(template: .freeform)
        XCTAssertTrue(vm.preset.surfaces.isEmpty, "freeformはコーナー面を持たない")
        XCTAssertEqual(vm.preset.extras.count, 1)
        XCTAssertNil(vm.selectedSurface)
        XCTAssertEqual(vm.selectedExtraID, vm.preset.extras.first?.id)
    }

    /// apply(.sample): contentSourceがtestPatternになる
    func testApplySampleTemplateSetsTestPattern() {
        let vm = makeVM()
        vm.contentSource = .none
        vm.apply(template: .sample)
        XCTAssertEqual(vm.contentSource, .testPattern)
        XCTAssertEqual(vm.preset.surfaces.count, 3, "sampleは3面コーナー構成")
    }
}

// MARK: - OSCMessage.parse(F-CTRL-1・§5.1 共有契約)

// OSC 1.0 のバイト列を手組みし、parse(純関数)の契約を直接検証する。
// エンコード規約: 文字列はnull終端+4バイト境界ゼロパディング、型タグは","始まり、
// 引数(Float32/Int32)はビッグエンディアン。
final class OSCMessageParseTests: XCTestCase {

    // MARK: OSCエンコードヘルパ

    /// OSC文字列: null終端し、4バイト境界までゼロパディング
    private func oscString(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0)
        while d.count % 4 != 0 { d.append(0) }
        return d
    }

    /// Float32(ビッグエンディアン・4バイト)
    private func oscFloat(_ value: Float) -> Data {
        var be = value.bitPattern.bigEndian
        return Data(bytes: &be, count: 4)
    }

    /// Int32(ビッグエンディアン・4バイト)
    private func oscInt(_ value: Int32) -> Data {
        var be = UInt32(bitPattern: value).bigEndian
        return Data(bytes: &be, count: 4)
    }

    /// 単一OSCメッセージ: アドレス + 型タグ(","始まり) + 引数群
    private func oscPacket(address: String, typeTags: String, args: [Data]) -> Data {
        var d = oscString(address)
        d.append(oscString("," + typeTags))
        for a in args { d.append(a) }
        return d
    }

    // MARK: テスト

    /// 引数なし("/cc/play"): floatsは空
    func testParsePlayNoArguments() {
        let data = oscPacket(address: "/cc/play", typeTags: "", args: [])
        let msg = OSCMessage.parse(data)
        XCTAssertEqual(msg?.address, "/cc/play")
        XCTAssertEqual(msg?.floats.count, 0, "引数なしのメッセージはfloatsが空のはず")
    }

    /// ",f" 単一Float32("/cc/brightness/frontWall" + 1.5)
    func testParseSingleFloat() {
        let data = oscPacket(address: "/cc/brightness/frontWall",
                             typeTags: "f", args: [oscFloat(1.5)])
        let msg = OSCMessage.parse(data)
        XCTAssertEqual(msg?.address, "/cc/brightness/frontWall")
        XCTAssertEqual(msg?.floats.count, 1)
        XCTAssertEqual(msg?.floats.first ?? .nan, 1.5, accuracy: 1e-6)
    }

    /// ",ff" 2つのFloat32("/cc/corner/leftWall/tl" + (0.2, 0.8))
    func testParseTwoFloats() {
        let data = oscPacket(address: "/cc/corner/leftWall/tl",
                             typeTags: "ff", args: [oscFloat(0.2), oscFloat(0.8)])
        let msg = OSCMessage.parse(data)
        XCTAssertEqual(msg?.address, "/cc/corner/leftWall/tl")
        XCTAssertEqual(msg?.floats.count, 2)
        XCTAssertEqual(msg?.floats[0] ?? .nan, 0.2, accuracy: 1e-6)
        XCTAssertEqual(msg?.floats[1] ?? .nan, 0.8, accuracy: 1e-6)
    }

    /// 型タグ",i"のInt32はFloatに変換される
    func testParseIntConvertedToFloat() {
        let data = oscPacket(address: "/cc/mode", typeTags: "i", args: [oscInt(1)])
        let msg = OSCMessage.parse(data)
        XCTAssertEqual(msg?.address, "/cc/mode")
        XCTAssertEqual(msg?.floats.count, 1)
        XCTAssertEqual(msg?.floats.first ?? .nan, 1.0, accuracy: 1e-6)
    }

    /// 空データはnil
    func testParseEmptyDataReturnsNil() {
        XCTAssertNil(OSCMessage.parse(Data()))
    }

    /// パディング破れ(null終端はあるが4バイト境界に整合しない9バイト)はnil
    func testParseBrokenPaddingReturnsNil() {
        var data = Data("/cc/play".utf8)   // 8バイト
        data.append(0)                     // null終端(計9バイト・4の倍数でない)
        XCTAssertNil(OSCMessage.parse(data),
                     "4バイト境界に整合しないOSCデータはnilを返すべき")
    }
}

// MARK: - 後方互換(mesh/masks/effectsキーの無い旧JSON)

final class ProBackwardCompatTests: XCTestCase {

    /// mesh/masks/effectsキーを持たない旧JSONもデコードでき、既定値(nil/neutral)になる。
    /// (EditingTests.testDecodingLegacyJSONWithoutExtras に準拠)
    func testDecodingLegacyJSONWithoutProKeys() throws {
        // いったんプロ機能を盛った状態をエンコードし、対応キーを削除して旧スキーマを再現する
        var modern = MappingPreset.makeDefault()
        modern.maskShapes = [MaskShape(quad: Quad(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))]
        modern.effectSettings = EffectSettings(saturation: 1.5, contrast: 1.2,
                                               brightness: 0.1, hueDegrees: 45)
        let modernQuad = modern.surfaces[.frontWall]!.quad
        modern.surfaces[.frontWall]?.mesh = WarpMesh.fromQuad(modernQuad, rows: 4, cols: 4)

        let data = try JSONEncoder().encode(modern)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // ルートの masks / effects を削除
        root.removeValue(forKey: "masks")
        root.removeValue(forKey: "effects")
        // 各面設定の mesh を削除
        if var surfaces = root["surfaces"] as? [String: [String: Any]] {
            for key in surfaces.keys { surfaces[key]?.removeValue(forKey: "mesh") }
            root["surfaces"] = surfaces
        }
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(MappingPreset.self, from: legacyData)
        XCTAssertTrue(decoded.maskShapes.isEmpty, "masksキーが無ければ空のはず")
        XCTAssertTrue(decoded.effectSettings.isNeutral, "effectsキーが無ければneutralのはず")
        XCTAssertNil(decoded.surfaces[.frontWall]?.mesh, "meshキーが無ければnilのはず")
        // 既存フィールドは通常どおり読める
        XCTAssertEqual(decoded.surfaces.count, 3)
    }
}
