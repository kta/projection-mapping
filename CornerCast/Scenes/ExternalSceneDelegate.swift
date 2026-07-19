import UIKit
import AVFoundation
import Metal
import QuartzCore

/// 外部ディスプレイシーン(F-OUT-1/2)。UIは一切載せない — 映像だけ。
///
/// - willConnectTo: windowScene.screen から解像度(currentMode)・refreshRateを取得し、
///   AppServices.shared.externalDisplayManager.externalSceneDidConnect(windowScene:host:) を呼ぶ。
///   UIWindowのrootには OutputHostViewController を設定。
/// - sceneDidDisconnect: externalDisplayManager.externalSceneDidDisconnect() を呼ぶ。
/// - このシーンは非インタラクティブ(タッチ不可)。UIボタン等を置いてはならない(F-OUT-2)。
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // 映像専用VC。SwiftUIビュー・UIコントロールは載せない(F-OUT-2)。
        let host = OutputHostViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        self.window = window
        window.makeKeyAndVisible()
        // Managerがhost.metalLayer(device等)へ触れる前にviewDidLoadを確実に走らせる。
        host.loadViewIfNeeded()

        AppServices.shared.externalDisplayManager
            .externalSceneDidConnect(windowScene: windowScene, host: host)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        AppServices.shared.externalDisplayManager.externalSceneDidDisconnect()
        window = nil
    }
}

/// 外部ディスプレイに表示する唯一のVC。
/// - リアルタイムモード: CAMetalLayer に OutputRenderer が描画する。
/// - ベイク再生モード(F-BAKE-2): AVPlayerLayer に切替えて再生する。
/// モード切替は ExternalDisplayManager から setMode(_:) で指示される。背景は常に黒。
final class OutputHostViewController: UIViewController {

    /// OutputRendererの描画先。プロパティ初期化時点で生成し、接続直後から参照可能にする。
    let metalLayer = CAMetalLayer()
    /// ベイク再生用。
    private let playerLayer = AVPlayerLayer()

    /// ベイク再生モードのプレイヤ(ExternalDisplayManagerが設定する)。
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // CAMetalLayer構成: CIContextがdrawableのテクスチャへ描画するため framebufferOnly=false が必須。
        // deviceを設定しないと nextDrawable() がnilを返すため、ここで必ず設定する。
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)

        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.isHidden = true
        view.layer.addSublayer(playerLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // レイヤのframeはpt。ピクセル解像度(drawableSize)はManagerが別途設定する(F-OUT-5)。
        // レイアウト時の暗黙アニメーションを抑止して映像のちらつきを防ぐ。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = view.bounds
        playerLayer.frame = view.bounds
        CATransaction.commit()
    }

    /// 出力モードに応じて表示レイヤを切替える。
    func setMode(_ mode: MappingViewModel.OutputMode) {
        switch mode {
        case .realtime:
            metalLayer.isHidden = false
            playerLayer.isHidden = true
        case .bakedPlayback:
            metalLayer.isHidden = true
            playerLayer.isHidden = false
        }
    }
}
