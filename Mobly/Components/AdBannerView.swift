import SwiftUI
import GoogleMobileAds

/// A sponsored "Google Ads" slot for the Home feed.
///
enum AdConfig {
    /// Google's official test banner. Replace with the production unit before
    /// enabling live monetization.
    static let bannerAdUnitID = "ca-app-pub-3940256099942544/2934735716"
}

struct AdBannerView: View {
    @ObservedObject private var config = RemoteConfigStore.shared

    /// Renders nothing while `ads.banner` is off; Home drops its padding too.
    var body: some View {
        if config.isEnabled("ads.banner") {
            AdMobBanner(adUnitID: AdConfig.bannerAdUnitID)
                .frame(height: 50)
                .padding(.horizontal, 22)
        }
    }
}

private struct AdMobBanner: UIViewRepresentable {
    let adUnitID: String

    func makeUIView(context: Context) -> BannerView {
        let view = BannerView(adSize: AdSizeBanner)
        view.adUnitID = adUnitID
        view.rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        view.load(Request())
        return view
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}
