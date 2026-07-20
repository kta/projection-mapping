import SwiftUI

/// クロップ編集(F-CROP-2/3): ソース映像のどの領域を各面(左壁/正面壁/床)に
/// 割り当てるかを編集する。矩形はドラッグで移動、右下ハンドルでリサイズ。
/// 面同士の重複は許容(F-CROP-3)。ガイドPNGの書き出し(F-SRC-5)もここから行う。
struct CropEditorView: View {
    @Bindable var viewModel: MappingViewModel
    @Environment(\.dismiss) private var dismiss

    /// 編集対象(コーナー3面+自由面)を同一UIで扱うための共通表現
    private struct CropTarget: Identifiable {
        let id: String              // "core:<rawValue>" / "extra:<uuid>"
        let name: String
        let color: Color
        let crop: CGRect
    }

    /// ジェスチャ開始時のcrop(1ジェスチャ=1アンドゥ単位の基準値)。CropTarget.idキー。
    @State private var dragBase: [String: CGRect] = [:]
    @State private var sourceImage: UIImage?
    @State private var guideURL: URL?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let canvas = MeshCanvasView.letterboxRect(in: geo.size)
                ZStack {
                    // 周囲はライトUI、ソース映像のフレームだけ黒(MeshCanvasViewと同じ役割分担)
                    Color(.secondarySystemBackground)
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: canvas.width, height: canvas.height)
                        .position(x: canvas.midX, y: canvas.midY)
                    backgroundView(in: canvas)
                    ForEach(cropTargets()) { target in
                        cropRectView(target, canvas: canvas)
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

    // MARK: - 編集対象の解決(コーナー3面+自由面)

    private func cropTargets() -> [CropTarget] {
        var targets: [CropTarget] = Surface.drawOrder.compactMap { s in
            guard let crop = viewModel.preset.surfaces[s]?.crop else { return nil }
            return CropTarget(id: "core:\(s.rawValue)", name: s.displayName,
                              color: Self.color(for: s), crop: crop)
        }
        for e in viewModel.preset.extras {
            targets.append(CropTarget(id: "extra:\(e.id.uuidString)", name: e.name,
                                      color: .green, crop: e.config.crop))
        }
        return targets
    }

    private func currentCrop(id: String) -> CGRect? {
        cropTargets().first { $0.id == id }?.crop
    }

    private func applyCrop(_ rect: CGRect, id: String) {
        if id.hasPrefix("core:"), let s = Surface(rawValue: String(id.dropFirst(5))) {
            viewModel.setCrop(rect, for: s)
        } else if id.hasPrefix("extra:"), let uuid = UUID(uuidString: String(id.dropFirst(6))) {
            viewModel.setExtraCrop(rect, id: uuid)
        }
    }

    // MARK: - クロップ矩形(移動+リサイズ)

    private func cropRectView(_ target: CropTarget, canvas: CGRect) -> some View {
        let crop = target.crop
        let rect = CGRect(x: canvas.minX + crop.minX * canvas.width,
                          y: canvas.minY + crop.minY * canvas.height,
                          width: crop.width * canvas.width,
                          height: crop.height * canvas.height)
        let color = target.color
        return ZStack {
            Rectangle().fill(color.opacity(0.15))
            Rectangle().strokeBorder(color, lineWidth: 2)
            Text(target.name)
                .font(.caption).bold()
                .foregroundStyle(color)
            // リサイズハンドル(右下)。移動ジェスチャより深い位置にあるため優先される。
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .position(x: rect.width, y: rect.height)
                .gesture(resizeGesture(target.id, canvas: canvas))
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .gesture(moveGesture(target.id, canvas: canvas))
        .allowsHitTesting(!viewModel.isEditLocked)
    }

    private func moveGesture(_ id: String, canvas: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragBase[id] == nil {
                    viewModel.beginGesture()
                    dragBase[id] = currentCrop(id: id)
                }
                guard let base = dragBase[id] else { return }
                applyCrop(
                    base.offsetBy(dx: value.translation.width / canvas.width,
                                  dy: value.translation.height / canvas.height),
                    id: id)
            }
            .onEnded { _ in dragBase[id] = nil }
    }

    private func resizeGesture(_ id: String, canvas: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragBase[id] == nil {
                    viewModel.beginGesture()
                    dragBase[id] = currentCrop(id: id)
                }
                guard let base = dragBase[id] else { return }
                let newSize = CGSize(
                    width: base.width + value.translation.width / canvas.width,
                    height: base.height + value.translation.height / canvas.height)
                applyCrop(CGRect(origin: base.origin, size: newSize), id: id)
            }
            .onEnded { _ in dragBase[id] = nil }
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
