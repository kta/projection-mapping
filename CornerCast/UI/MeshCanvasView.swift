import SwiftUI

/// メッシュ編集キャンバス(F-UI-1)。
/// 3面のワイヤーフレーム+12個のコントロールポイントを描画し、ドラッグで頂点を動かす。
///
/// TODO(TASK UI-1 / 担当: ui agent):
/// - GeometryReaderで自サイズを取得。キャンバスのアスペクト比は出力(16:9)に固定し、
///   レターボックスで中央配置する。
/// - 各Surfaceのquadを Path で描画(選択中の面はハイライト)。面の識別色は
///   TestPatternGeneratorと同じ(左壁=シアン/正面壁=マゼンタ/床=イエロー)。
/// - コントロールポイント: 見た目20pt・タッチ判定44pt以上(contentShapeで拡大)。
///   DragGesture(minimumDistance: 0)で
///     onChanged初回: viewModel.beginGesture() → 以降 viewModel.move(corner:of:to:)
///   座標変換は CoordinateMapper.normalized(fromUI:in:) を使う(手計算禁止)。
/// - viewModel.isEditLocked 時はジェスチャ無効+ポイントを半透明表示(F-UI-6)。
/// - 選択状態: タップで selectedSurface/selectedCorner を更新(InspectorViewと連動)。
/// - 背景プレビュー(F-OUT-4)は初版ではワイヤーフレームのみでよい(実映像プレビューはM2)。
struct MeshCanvasView: View {
    @Bindable var viewModel: MappingViewModel

    var body: some View {
        Text("TODO: UI-1 MeshCanvasView") // TODO: UI-1
    }
}
