import SwiftUI

/// かんたんセットアップ(F-EASY-1): 「3面コーナー」を選んだ初心者向けのステップ式ガイド。
///
/// 設計原則(HIG: Progressive Disclosure):
/// - 1画面につき、やることは1つだけ。12点を同時に見せず、面ごとに4つの丸だけを出す。
/// - 専門用語ゼロ。「射影変換」ではなく「枠を壁に合わせる」。色は「水色/ピンク/黄色」と呼ぶ。
/// - 文字は大きく(セマンティックフォント=Dynamic Type対応)、ボタンは大きく、道は一本。
/// - いつでも「くわしい設定」へ抜けられる(閉じ込めない)。
struct SimpleSetupView: View {
    @Bindable var viewModel: MappingViewModel
    /// 完了・スキップ時に呼ばれる(親のWelcomeViewが自身を閉じる)
    let onFinish: () -> Void

    /// 0=接続, 1=左壁, 2=正面壁, 3=床, 4=動画えらび, 5=完了
    @State private var step = 0
    @State private var showContentPicker = false

    private static let adjustOrder: [Surface] = [.leftWall, .frontWall, .floor]
    private static let lastStep = 5

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.horizontal, 32)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            // 壁に映る模様(テストパターン)と画面の枠を対応づける
            viewModel.contentSource = .testPattern
            syncSelection()
        }
        .onChange(of: step) { _, _ in syncSelection() }
        .sheet(isPresented: $showContentPicker) {
            ContentPickerView(viewModel: viewModel)
        }
    }

    // MARK: - ヘッダー(見出し+進みぐあい)

    private var header: some View {
        VStack(spacing: 12) {
            progressDots
            Text(stepTitle)
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(stepCaption)
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0...Self.lastStep, id: \.self) { i in
                Circle()
                    .fill(i <= step ? Color.accentColor : Color.white.opacity(0.2))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel("ステップ \(step + 1) / \(Self.lastStep + 1)")
    }

    private var stepTitle: String {
        switch step {
        case 0: return "プロジェクターに つなぎましょう"
        case 1: return "水色の枠を「左の壁」に合わせましょう"
        case 2: return "ピンクの枠を「正面の壁」に合わせましょう"
        case 3: return "黄色の枠を「床」に合わせましょう"
        case 4: return "映したい動画を えらびましょう"
        default: return "できあがり!"
        }
    }

    private var stepCaption: String {
        switch step {
        case 0:
            return "iPadとプロジェクターをHDMIケーブルでつなぐと、壁に色つきの模様が映ります。"
        case 1, 2, 3:
            return "壁に映っている模様を見ながら、4つの白い丸を指でうごかして、部屋の角にぴったり合わせてください。"
        case 4:
            return "写真アプリやファイルから、お好きな動画や写真をえらべます。"
        default:
            return "あとから右上のボタンで、いつでも調整しなおせます。"
        }
    }

    // MARK: - 本文(ステップごとの中身)

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            connectContent
        case 1, 2, 3:
            SimpleAdjustCanvas(viewModel: viewModel,
                               surface: Self.adjustOrder[step - 1])
                .padding(20)
        case 4:
            contentPickContent
        default:
            doneContent
        }
    }

    private var connectContent: some View {
        VStack(spacing: 24) {
            Image(systemName: viewModel.displayState.isConnected
                  ? "checkmark.circle.fill" : "cable.connector.horizontal")
                .font(.system(size: 88, weight: .light))
                .foregroundStyle(viewModel.displayState.isConnected ? Color.green : .white.opacity(0.8))
                .contentTransition(.symbolEffect(.replace))
            if viewModel.displayState.isConnected {
                Text("つながりました!")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.green)
            } else {
                Text("つながると、ここに「つながりました!」と出ます")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var contentPickContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 88, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Button {
                showContentPicker = true
            } label: {
                Label("動画・写真をえらぶ", systemImage: "plus")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if case .video = viewModel.contentSource {
                Label("動画をえらびました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            } else if case .image = viewModel.contentSource {
                Label("写真をえらびました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            }
        }
    }

    private var doneContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(Color.green)
            Text("お部屋が映画館になりました")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - フッター(もどる / 次へ)

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                if step > 0 {
                    Button {
                        step -= 1
                    } label: {
                        Text("もどる")
                            .font(.title3)
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                Button {
                    if step == Self.lastStep {
                        onFinish()
                    } else {
                        step += 1
                    }
                } label: {
                    Text(nextTitle)
                        .font(.title3.weight(.semibold))
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Button("くわしい設定を使う") {
                onFinish()
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var nextTitle: String {
        switch step {
        case 0: return viewModel.displayState.isConnected ? "次へ" : "あとでつなぐ"
        case 4: return isContentChosen ? "次へ" : "あとでえらぶ"
        case Self.lastStep: return "はじめる"
        default: return "次へ"
        }
    }

    private var isContentChosen: Bool {
        switch viewModel.contentSource {
        case .video, .image: return true
        default: return false
        }
    }

    // MARK: - 選択同期(外部ディスプレイ・プレビューのハイライトと一致させる)

    private func syncSelection() {
        if (1...3).contains(step) {
            viewModel.selectedSurface = Self.adjustOrder[step - 1]
        } else {
            viewModel.selectedSurface = nil
        }
        viewModel.selectedCorner = nil
        viewModel.selectedExtraID = nil
        viewModel.selectedMaskID = nil
    }
}

// MARK: - 1面だけの調整キャンバス

/// かんたんモード専用キャンバス: 対象の面「だけ」を表示し、4つの大きな丸で合わせる。
/// 12点同時表示のプロ用キャンバスとの最大の違いは「見せる情報を1面に絞る」こと。
private struct SimpleAdjustCanvas: View {
    let viewModel: MappingViewModel
    let surface: Surface

    @State private var previewImage: UIImage?

    var body: some View {
        GeometryReader { geo in
            let canvasRect = MeshCanvasView.letterboxRect(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.04))
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .frame(width: canvasRect.width, height: canvasRect.height)
                        .position(x: canvasRect.midX, y: canvasRect.midY)
                        .opacity(0.9)
                }
                if let quad = viewModel.preset.surfaces[surface]?.quad {
                    quadPath(quad, in: canvasRect)
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineJoin: .round))
                    ForEach(Quad.Corner.allCases) { corner in
                        BigHandle(viewModel: viewModel, surface: surface,
                                  corner: corner, canvasRect: canvasRect, color: color)
                    }
                }
            }
            .coordinateSpace(name: "SimpleSetup.canvas")
            .task(id: previewKey) {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                previewImage = EditorPreviewRenderer.shared.render(
                    preset: viewModel.preset,
                    content: viewModel.contentSource,
                    size: CGSize(width: 640, height: 360))
            }
        }
    }

    private var previewKey: String {
        viewModel.preset.calibrationFingerprint
    }

    private var color: Color {
        switch surface {
        case .leftWall: return .cyan
        case .frontWall: return Color(red: 1, green: 0.26, blue: 0.85)
        case .floor: return .yellow
        }
    }

    private func quadPath(_ q: Quad, in rect: CGRect) -> Path {
        var path = Path()
        let pts = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft]
            .map { MeshCanvasView.uiPoint($0, in: rect) }
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }
}

/// かんたんモードの大きなハンドル(見た目28pt・タッチ60pt。白い丸=「うごかす所」)
private struct BigHandle: View {
    let viewModel: MappingViewModel
    let surface: Surface
    let corner: Quad.Corner
    let canvasRect: CGRect
    let color: Color

    @State private var began = false

    var body: some View {
        let normalized = viewModel.preset.surfaces[surface]?.quad[corner] ?? .zero
        let pos = MeshCanvasView.uiPoint(normalized, in: canvasRect)

        ZStack {
            Circle().fill(.white).frame(width: 28, height: 28)
            Circle().stroke(color, lineWidth: 4).frame(width: 28, height: 28)
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
        .frame(width: 60, height: 60)
        .contentShape(Circle())
        .position(pos)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("SimpleSetup.canvas"))
                .onChanged { value in
                    if !began {
                        began = true
                        viewModel.beginGesture()
                    }
                    let norm = MeshCanvasView.normalized(value.location, in: canvasRect)
                    viewModel.move(corner: corner, of: surface, to: norm)
                }
                .onEnded { _ in began = false }
        )
        .accessibilityLabel("\(surface.displayName)の角")
        .accessibilityHint("ドラッグして部屋の角に合わせます")
    }
}
