import XCTest
@testable import CornerCast

/// TODO(TASK TEST-1 / 担当: test agent):
/// ドメイン層のユニットテスト。実装済みコード(Models/CoordinateMapper/MappingViewModel/
/// FrameComposer)に対して書く。最低限以下をカバーすること:
///
/// CoordinateMapper:
/// - normalized(fromUI:) ⇔ ui(fromNormalized:) のラウンドトリップ
/// - ciPixel: (0,0)左上 → (0, H)、(1,1)右下 → (W, 0) になること(Y反転の検証)
/// - ciRect: 正規化(0,0,0.5,0.5)=「左上1/4」が extent の左上1/4(CIでは上半分の左)に写ること
///
/// Quad:
/// - clamped: 範囲外座標が0-1に収まる
/// - subscript get/setの全Corner
///
/// MappingPreset:
/// - makeDefault: 3面すべて存在、links4本
/// - calibrationFingerprint: quadを動かすと変化し、name/updatedAt変更では不変
/// - Codableラウンドトリップ(JSONEncoder→Decoderで等価)
///
/// MappingViewModel(@MainActorテスト):
/// - move: クランプされる/リンク有効時に相手頂点が追従する/無効時は追従しない
/// - undo: beginGesture→move→undoで元に戻る、上限20
/// - resetSurface: 対象面のみ既定値に戻る
///
/// FrameComposer:
/// - compose結果のextentが(0,0,canvasSize)に一致する
/// - surfaces空でも黒キャンバスが返る(クラッシュしない)
/// ※ CIImageのピクセル値検証はCIContextレンダリングが必要でシミュレータ依存のため、
///   extent検証とレシピ構築がクラッシュしないことの確認まででよい。
final class DomainTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true) // TODO: TEST-1
    }
}
