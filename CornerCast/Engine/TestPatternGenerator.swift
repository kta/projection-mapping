import CoreImage

/// テストパターン(F-UI-2): キャリブレーション時に投影する、面ごとに色分けされたグリッド。
/// FrameComposerへの入力(ソースフレーム相当)として使うため、
/// 「超広角ソース動画と同じ形」= 各面のcrop領域にそれぞれの面のパターンが入った1枚 を生成する。
///
/// TODO(TASK ENG-1 / 担当: engine agent):
/// - generate(size:params:) で以下を描いた CIImage を返す:
///   * 各面のcrop領域(params.surfaces[i].crop)に、面の識別色
///     (左壁=シアン / 正面壁=マゼンタ / 床=イエロー)の外周枠+10x10グリッド+対角線
///   * 面ラベル(「左壁」等)を中央に大きく描画
///   * crop領域外は黒
/// - 実装はUIGraphicsImageRenderer(またはCGContext)で一度だけ描画→CIImage化し、
///   paramsのcrop構成が変わらない限りキャッシュを返す(毎フレーム再描画しない)。
/// - キャッシュキーは crop矩形群のハッシュでよい(quadの変化では再生成不要 —
///   quadはFrameComposer側で適用されるため)。
final class TestPatternGenerator: FrameSource {
    private var cached: CIImage?
    private var cacheKey: String?

    /// レンダラから毎フレーム呼ばれる。paramsはupdate(params:)で事前に渡す。
    private var params: RenderParameters?
    private let sourceSize = CGSize(width: 1920, height: 1080)

    func update(params: RenderParameters) {
        self.params = params
    }

    func copyFrame(forHostTime hostTime: CFTimeInterval) -> CIImage? {
        nil // TODO: ENG-1 — キャッシュ有効ならcached、無効なら再生成
    }
}
