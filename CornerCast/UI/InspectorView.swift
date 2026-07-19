import SwiftUI
import Foundation

/// インスペクタ(F-UI-3/4/5、F-WARP-5/6)。選択中の面・頂点に対する精密操作。
///
/// セクション構成(TASK UI-2):
/// 1. 選択中の面/頂点の座標数値表示+直接入力(F-UI-5)
/// 2. 微調整十字キー(F-UI-3): タップで±1px、長押しでリピート
/// 3. 面の明るさ/ガンマ Slider(F-WARP-6)
/// 4. 頂点リンク Toggle(F-WARP-5)
/// 5. リセット(面/全体)+アンドゥ+編集ロック(F-UI-4/6)
struct InspectorView: View {
    @Bindable var viewModel: MappingViewModel

    var body: some View {
        Form {
            selectionSection
            nudgeSection
            colorSection
            meshSection
            extrasSection
            maskSection
            linkSection
            resetSection
        }
    }

    // MARK: 1. 選択中の頂点座標(F-UI-5)

    @ViewBuilder private var selectionSection: some View {
        Section("選択中の頂点") {
            if let s = viewModel.selectedSurface, let c = viewModel.selectedCorner {
                Text("\(s.displayName) / \(cornerName(c))")
                    .font(.subheadline).bold()
                HStack {
                    Text("X")
                    TextField("X", value: coordBinding(s, c, axis: .horizontal),
                              format: .number.precision(.fractionLength(3)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                HStack {
                    Text("Y")
                    TextField("Y", value: coordBinding(s, c, axis: .vertical),
                              format: .number.precision(.fractionLength(3)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
            } else {
                Text("キャンバス上の点を選択してください")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: 2. 微調整十字キー(F-UI-3)

    @ViewBuilder private var nudgeSection: some View {
        Section("微調整(±1px)") {
            if let s = viewModel.selectedSurface, let c = viewModel.selectedCorner {
                VStack(spacing: 8) {
                    NudgeButton(systemName: "arrow.up") { viewModel.nudge(corner: c, of: s, dx: 0, dy: -1) }
                    HStack(spacing: 24) {
                        NudgeButton(systemName: "arrow.left") { viewModel.nudge(corner: c, of: s, dx: -1, dy: 0) }
                        NudgeButton(systemName: "arrow.right") { viewModel.nudge(corner: c, of: s, dx: 1, dy: 0) }
                    }
                    NudgeButton(systemName: "arrow.down") { viewModel.nudge(corner: c, of: s, dx: 0, dy: 1) }
                }
                .frame(maxWidth: .infinity)
                .disabled(viewModel.isEditLocked)
            } else {
                Text("点を選択すると微調整できます")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    // MARK: 3. 明るさ/ガンマ(F-WARP-6)

    @ViewBuilder private var colorSection: some View {
        if let s = viewModel.selectedSurface {
            Section("\(s.displayName)の補正") {
                VStack(alignment: .leading) {
                    Text("明るさ \(brightnessBinding(s).wrappedValue, format: .number.precision(.fractionLength(2)))")
                        .font(.caption)
                    Slider(value: brightnessBinding(s), in: 0.25...2.0) { editing in
                        if editing { viewModel.beginGesture() }   // 1操作=1アンドゥ単位
                    }
                }
                VStack(alignment: .leading) {
                    Text("ガンマ \(gammaBinding(s).wrappedValue, format: .number.precision(.fractionLength(2)))")
                        .font(.caption)
                    Slider(value: gammaBinding(s), in: 0.25...4.0) { editing in
                        if editing { viewModel.beginGesture() }
                    }
                }
                VStack(alignment: .leading) {
                    Text("エッジぼかし \(featherBinding(s).wrappedValue, format: .number.precision(.fractionLength(2)))")
                        .font(.caption)
                    Slider(value: featherBinding(s), in: 0...0.3) { editing in
                        if editing { viewModel.beginGesture() }
                    }
                }
            }
        }
    }

    // MARK: メッシュワープ(F-MESH-1)

    /// 選択中のコーナー面のメッシュワープ有効/無効。自由面のトグルはextrasSection内。
    @ViewBuilder private var meshSection: some View {
        if let s = viewModel.selectedSurface {
            Section("ワープ") {
                Toggle(isOn: meshBinding(s)) {
                    Label("メッシュワープ(4×4)", systemImage: "grid")
                }
                .disabled(viewModel.isEditLocked)
            }
        }
    }

    // MARK: 自由面(F-FREE-1)

    @ViewBuilder private var extrasSection: some View {
        Section("追加面") {
            Button {
                viewModel.addExtraSurface()
            } label: {
                Label("面を追加", systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(viewModel.isEditLocked)

            if let id = viewModel.selectedExtraID,
               let extra = viewModel.preset.extras.first(where: { $0.id == id }) {
                TextField("名前", text: extraNameBinding(id))
                    .textFieldStyle(.roundedBorder)
                extraSlider("明るさ", id: id, keyPath: \.brightness, range: 0.25...2.0,
                            current: extra.config.brightness)
                extraSlider("ガンマ", id: id, keyPath: \.gamma, range: 0.25...4.0,
                            current: extra.config.gamma)
                extraSlider("エッジぼかし", id: id, keyPath: \.feather, range: 0...0.3,
                            current: extra.config.feather)
                Toggle(isOn: extraMeshBinding(id)) {
                    Label("メッシュワープ(4×4)", systemImage: "grid")
                }
                .disabled(viewModel.isEditLocked)
                Button(role: .destructive) {
                    viewModel.removeExtraSurface(id: id)
                } label: {
                    Label("この面を削除", systemImage: "trash")
                }
            } else if !viewModel.preset.extras.isEmpty {
                Text("キャンバス上の追加面(緑)をタップすると編集できます")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private func extraSlider(_ title: String, id: UUID,
                             keyPath: WritableKeyPath<SurfaceConfig, Double>,
                             range: ClosedRange<Double>, current: Double) -> some View {
        VStack(alignment: .leading) {
            Text("\(title) \(current, format: .number.precision(.fractionLength(2)))")
                .font(.caption)
            Slider(value: extraConfigBinding(id, keyPath: keyPath), in: range) { editing in
                if editing { viewModel.beginGesture() }
            }
        }
    }

    // MARK: 出力マスク(F-MASK-1)

    @ViewBuilder private var maskSection: some View {
        Section("マスク") {
            Button {
                viewModel.addMask()
            } label: {
                Label("マスクを追加", systemImage: "plus.square")
            }
            .disabled(viewModel.isEditLocked)

            if let id = viewModel.selectedMaskID,
               viewModel.preset.maskShapes.contains(where: { $0.id == id }) {
                TextField("名前", text: maskNameBinding(id))
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    viewModel.removeMask(id: id)
                } label: {
                    Label("このマスクを削除", systemImage: "trash")
                }
                .disabled(viewModel.isEditLocked)
            } else if !viewModel.preset.maskShapes.isEmpty {
                Text("キャンバス上のマスク(赤)をタップすると編集できます")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    // MARK: 4. 頂点リンク(F-WARP-5)

    @ViewBuilder private var linkSection: some View {
        Section("頂点リンク") {
            if viewModel.preset.links.isEmpty {
                Text("リンクはありません").foregroundStyle(.secondary).font(.caption)
            }
            ForEach(viewModel.preset.links) { link in
                Toggle(isOn: linkBinding(link)) {
                    Text(linkLabel(link)).font(.caption)
                }
            }
        }
    }

    // MARK: 5. リセット / アンドゥ / ロック(F-UI-4/6)

    @ViewBuilder private var resetSection: some View {
        Section {
            Button {
                viewModel.undo()
            } label: {
                Label("元に戻す", systemImage: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)

            Button {
                if let s = viewModel.selectedSurface { viewModel.resetSurface(s) }
            } label: {
                Label("この面をリセット", systemImage: "arrow.counterclockwise")
            }
            .disabled(viewModel.selectedSurface == nil)

            Button(role: .destructive) {
                viewModel.resetAll()
            } label: {
                Label("全てリセット", systemImage: "trash")
            }
        }
        Section {
            Toggle(isOn: $viewModel.isEditLocked) {
                Label("編集ロック", systemImage: "lock")
            }
        }
    }

    // MARK: - バインディング / ラベル

    /// 頂点座標のバインディング。set時は beginGesture→move でクランプ・リンク解決・アンドゥを通す。
    private func coordBinding(_ s: Surface, _ c: Quad.Corner, axis: Axis) -> Binding<Double> {
        Binding(
            get: {
                let p = viewModel.preset.surfaces[s]?.quad[c] ?? .zero
                return axis == .horizontal ? Double(p.x) : Double(p.y)
            },
            set: { v in
                guard let p = viewModel.preset.surfaces[s]?.quad[c] else { return }
                viewModel.beginGesture()
                let np = axis == .horizontal
                    ? CGPoint(x: v, y: p.y)
                    : CGPoint(x: p.x, y: v)
                viewModel.move(corner: c, of: s, to: np)
            }
        )
    }

    // 明るさ/ガンマは preset を直接更新(didSetで自動保存)。
    // アンドゥはSliderのonEditingChanged開始時に beginGesture を積むことで対応済み。
    private func brightnessBinding(_ s: Surface) -> Binding<Double> {
        Binding(
            get: { viewModel.preset.surfaces[s]?.brightness ?? 1.0 },
            set: { viewModel.preset.surfaces[s]?.brightness = $0 }
        )
    }

    private func gammaBinding(_ s: Surface) -> Binding<Double> {
        Binding(
            get: { viewModel.preset.surfaces[s]?.gamma ?? 1.0 },
            set: { viewModel.preset.surfaces[s]?.gamma = $0 }
        )
    }

    private func featherBinding(_ s: Surface) -> Binding<Double> {
        Binding(
            get: { viewModel.preset.surfaces[s]?.feather ?? 0.0 },
            set: { viewModel.preset.surfaces[s]?.feather = $0 }
        )
    }

    /// コーナー面のメッシュワープ有効/無効(setMeshEnabledでアンドゥ・初期化を通す)
    private func meshBinding(_ s: Surface) -> Binding<Bool> {
        Binding(
            get: { viewModel.preset.surfaces[s]?.mesh != nil },
            set: { viewModel.setMeshEnabled($0, for: s) }
        )
    }

    /// 自由面のメッシュワープ有効/無効(setExtraMeshEnabled経由)
    private func extraMeshBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { viewModel.preset.extras.first { $0.id == id }?.config.mesh != nil },
            set: { viewModel.setExtraMeshEnabled($0, id: id) }
        )
    }

    /// マスク名。名前変更APIが無いためpreset.maskShapesを直接更新する(didSetで自動保存)。
    private func maskNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { viewModel.preset.maskShapes.first { $0.id == id }?.name ?? "" },
            set: { name in
                guard let i = viewModel.preset.maskShapes.firstIndex(where: { $0.id == id }) else { return }
                viewModel.preset.maskShapes[i].name = name
            }
        )
    }

    private func extraNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { viewModel.preset.extras.first { $0.id == id }?.name ?? "" },
            set: { name in viewModel.updateExtra(id: id) { $0.name = name } }
        )
    }

    private func extraConfigBinding(_ id: UUID,
                                    keyPath: WritableKeyPath<SurfaceConfig, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.preset.extras.first { $0.id == id }?.config[keyPath: keyPath] ?? 1.0 },
            set: { v in viewModel.updateExtra(id: id) { $0.config[keyPath: keyPath] = v } }
        )
    }

    private func linkBinding(_ link: CornerLink) -> Binding<Bool> {
        Binding(
            get: { link.enabled },
            set: { viewModel.setLink(id: link.id, enabled: $0) }
        )
    }

    private func linkLabel(_ link: CornerLink) -> String {
        "\(link.a.surface.displayName)・\(cornerName(link.a.corner)) ↔ "
            + "\(link.b.surface.displayName)・\(cornerName(link.b.corner))"
    }

    private func cornerName(_ c: Quad.Corner) -> String {
        switch c {
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomRight: return "右下"
        case .bottomLeft: return "左下"
        }
    }
}

// MARK: - 微調整ボタン(タップ=単発、長押し=リピート)

/// 十字キー1つぶん。タップで1回、長押しで0.1秒間隔のリピート(F-UI-3)。
private struct NudgeButton: View {
    let systemName: String
    let action: () -> Void

    @State private var timer: Timer?

    var body: some View {
        Image(systemName: systemName)
            .font(.title2)
            .frame(width: 44, height: 44)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture {
                action()
            }
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 20) {
                // 長押し確定 → リピート開始
                startRepeat()
            } onPressingChanged: { pressing in
                if !pressing { stopRepeat() }
            }
    }

    private func startRepeat() {
        stopRepeat()
        action()   // 確定直後に1発
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            // Timerコールバックはnonisolated。メインスレッドで発火するためassumeIsolatedで包む。
            MainActor.assumeIsolated { action() }
        }
    }

    private func stopRepeat() {
        timer?.invalidate()
        timer = nil
    }
}
