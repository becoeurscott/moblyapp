import SwiftUI

/// A sponsored "Google Ads" slot for the Home feed.
///
/// By default this renders an on-brand placeholder so the app builds without
/// the AdMob SDK. To show REAL ads:
///   1. Add the Google Mobile Ads SDK via Swift Package Manager:
///      https://github.com/googleads/swift-package-manager-google-mobile-ads
///   2. In Info.plist set `GADApplicationIdentifier` to your AdMob app ID and
///      add the `SKAdNetworkItems` + `NSUserTrackingUsageDescription` keys.
///   3. In `MoblyApp` (@main), call `MobileAds.shared.start()` on launch.
///   4. Set `AdConfig.enabled = true` and put your real banner ad-unit ID in
///      `AdConfig.bannerAdUnitID`, then uncomment the `AdMobBanner` block below.
enum AdConfig {
    /// Flip to true once the AdMob SDK is added + configured.
    static let enabled = false

    /// Google's official TEST banner unit — safe to use during development.
    /// Replace with your real ca-app-pub-…/… id for production.
    static let bannerAdUnitID = "ca-app-pub-3940256099942544/2934735716"
}

struct AdBannerView: View {
    var body: some View {
        placeholder
            .padding(.horizontal, 22)
    }

    private var placeholder: some View {
        Image("AdBanner")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Real AdMob wrapper (uncomment once the SDK is installed)
//
// import GoogleMobileAds
//
// struct AdMobBanner: UIViewRepresentable {
//     let adUnitID: String
//     func makeUIView(context: Context) -> BannerView {
//         let banner = BannerView(adSize: AdSizeBanner)
//         banner.adUnitID = adUnitID
//         banner.rootViewController = UIApplication.shared.firstKeyWindow?.rootViewController
//         banner.load(Request())
//         return banner
//     }
//     func updateUIView(_ uiView: BannerView, context: Context) {}
// }
//
// private extension UIApplication {
//     var firstKeyWindow: UIWindow? {
//         connectedScenes.compactMap { $0 as? UIWindowScene }
//             .flatMap { $0.windows }.first { $0.isKeyWindow }
//     }
// }
