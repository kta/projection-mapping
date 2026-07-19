import SwiftUI

/// クロップ編集(F-CROP-2/3): ソース映像のどの領域を各面(左壁/正面壁/床)に
/// 割り当てるかを編集する。矩形はドラッグで移動、右下ハンドルでリサイズ。
/// 面同士の重複は許容(F-CROP-3)。ガイドPNGの書き出し(F-SRC-5)もここから行う。
struct CropEditorView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    /// ジェスチャ開始時のcrop(1ジェスチャ=1アンドゥ単位の基準値)
    @State private var dragBase: [Surface: CGRect] = [:]
    @State private var sourceImage: UIImage?
    @State private var guideURL: URL?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let canvas = MeshCanvasView.letterboxRect(in: geo.size)
                ZStack {
                    Color.black
                    backgroundView(in: canvas)
                    ForEach(Surface.drawOrder, id: \.self) { s in
                        if let crop = viewModel.preset.surfaces[s]?.crop {
                            cropRectView(s, crop: crop, canvas: canvas)
                        }
                    }
                }
            }
            .navigationTitle("クロップ編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    guideShareLink
                }
            }
            .onAppear {
                sourceImage = EditorPreviewRenderer.shared.sourcePreview(
                    content: viewModel.contentSource,
                    size: CGSize(width: 640, height: 360))
                prepareGuide()
            }
            .onChange(of: viewModel.preset.calibrationFingerprint) { _, _ in
                prepareGuide()
            }
        }
    }

    // MARK: - 背景(ソース映像 or グリッド)

    @ViewBuilder private func backgroundView(in canvas: CGRect) -> some View {
        if let sourceImage {
            Image(uiImage: sourceImage)
                .resizable()
                .frame(width: canvas.width, height: canvas.height)
                .position(x: canvas.midX, y: canvas.midY)
                .opacity(0.85)
        } else {
            gridPath(in: canvas)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
    }

    private func gridPath(in rect: CGRect) -> Path {
        var p = Path()
        for i in 0...10 {
            let t = CGFloat(i) / 10
            p.move(to: CGPoint(x: rect.minX + rect.width * t, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * t, y: rect.maxY))
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * t))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * t))
        }
        return p
    }

    // MARK: - クロップ矩形(移動+リサイズ)

    private func cropRectView(_ s: Surface, crop: CGRect, canvas: CGRect) -> some View {
        let rect = CGRect(x: canvas.minX + crop.minX * canvas.width,
                          y: canvas.minY + crop.minY * canvas.height,
                          width: crop.width * canvas.width,
                          height: crop.height * canvas.height)
        let color = Self.color(for: s)
        return ZStack {
            Rectangle().fill(color.opacity(0.15))
            Rectangle().strokeBorder(color, lineWidth: 2)
            Text(s.displayName)
                .font(.caption).bold()
                .foregroundStyle(color)
            // リサイズハンドル(右下)。移動ジェスチャより深い位置にあるため優先される。
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .position(x: rect.width, y: rect.height)
                .gesture(resizeGesture(s, canvas: canvas))
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .gesture(moveGesture(s, canvas: canvas))
        .allowsHitTesting(!viewModel.isEditLocked)
    }

    private func moveGesture(_ s: Surface, canvas: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragBase[s] == nil {
                    viewModel.beginGesture()
                    dragBase[s] = viewModel.preset.surfaces[s]?.crop
                }
                guard let base = dragBase[s] else { return }
                viewModel.setCrop(
                    base.offsetBy(dx: value.translation.width / canvas.width,
                                  dy: value.translation.height / canvas.height),
                    for: s)
            }
            .onEnded { _ in dragBase[s] = nil }
    }

    private func resizeGesture(_ s: Surface, canvas: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragBase[s] == nil {
                    viewModel.beginGesture()
                    dragBase[s] = viewModel.preset.surfaces[s]?.crop
                }
                guard let base = dragBase[s] else { return }
                let newSize = CGSize(
                    width: base.width + value.translation.width / canvas.width,
                    height: base.height + value.translation.height / canvas.height)
                viewModel.setCrop(CGRect(origin: base.origin, size: newSize), for: s)
            }
            .onEnded { _ in dragBase[s] = nil }
    }

    // MARK: - ガイドPNG書き出し(F-SRC-5)

    @ViewBuilder private var guideShareLink: some View {
        if let guideURL {
            ShareLink(item: guideURL) {
                Label("ガイド書き出し", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// 現在のクロップ構成からガイドPNGをtmpへ生成し、ShareLink対象にする
    private func prepareGuide() {
        guard let data = CropGuideExporter.pngData(preset: viewModel.preset) else {
            guideURL = nil
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CornerCast-CropGuide")
            .appendingPathExtension("png")
        do {
            try data.write(to: url, options: .atomic)
            guideURL = url
        } catch {
            guideURL = nil
        }
    }

    static func color(for s: Surface) -> Color {
        switch s {
        case .leftWall: return .cyan
        case .frontWall: return Color(red: 1, green: 0, blue: 1)
        case .floor: return .yellow
        }
    }
}
