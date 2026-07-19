import UIKit
import AVFoundation

/// 外部ディスプレイシーン(F-OUT-1/2)。UIは一切載せない — 映像だけ。
///
/// TODO(TASK EXT-1 / 担当: scenes agent):
/// - willConnectTo: windowScene.screen から解像度(currentMode)・refreshRateを取得し、
///   AppServices.shared.externalDisplayManager.externalSceneDidConnect(windowScene:) を呼ぶ。
///   UIWindowのrootには OutputHostViewController(下記)を設定。
/// - sceneDidDisconnect: externalDisplayManager.externalSceneDidDisconnect() を呼ぶ。
/// - このシーンは非インタラクティブ(タッチ不可)。UIボタン等を置いてはならない(F-OUT-2)。
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // TODO: EXT-1
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // TODO: EXT-1
    }
}

/// 外部ディスプレイに表示する唯一のVC。
///
/// TODO(TASK EXT-1):
/// - リアルタイムモード: view.layerに CAMetalLayer を追加し(frame=bounds,
///   drawableSize=画面ピクセル解像度)、OutputRendererに渡す。
/// - ベイク再生モード(F-BAKE-2): AVPlayerLayer(videoGravity: .resizeAspect)に切替。
///   モード切替は ExternalDisplayManager から指示される(setMode(_:)を公開)。
/// - 背景は常に黒。ステータスバー等は出さない。
final class OutputHostViewController: UIViewController {
    // TODO: EXT-1
}
