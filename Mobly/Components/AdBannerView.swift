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
        VStack(alignment: .leading, spacing: 8) {
            Text("SPONSORISÉ")
                .font(.moblyBody(10, weight: .bold))
                .foregroundStyle(Color(hex: 0x9A9DAC))
                .tracking(0.5)

            if AdConfig.enabled {
                // Real AdMob banner (requires the SDK — see the header comment).
                // AdMobBanner(adUnitID: AdConfig.bannerAdUnitID)
                //     .frame(height: 90)
                //     .clipShape(RoundedRectangle(cornerRadius: 16))
                placeholder
            } else {
                placeholder
            }
        }
        .padding(.horizontal, 22)
    }

    // On-brand placeholder that reads as an ad slot until AdMob is wired.
    private var placeholder: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xEEF0FE))
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.moblyPrimary)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text("Votre publicité ici")
                    .font(.moblyHeading(14)).foregroundStyle(Color.moblyTextPrimary)
                Text("Espace Google Ads · touchez des milliers d'utilisateurs")
                    .font(.moblyBody(11.5)).foregroundStyle(Color(hex: 0x9A9DAC))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: 0xC4C7D2))
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(Color(hex: 0xE2E4EC)))
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
