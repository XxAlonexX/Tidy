import Foundation

/// Fill these in from your Dodo Payments dashboard before shipping.
enum Config {
    /// Product ID of the ₹69 one-time product with a License Key entitlement attached (looks like `pdt_...`).
    static let dodoProductID = "pdt_0Np0aJHLTsLsCZLnOs7FG"

    /// `true` for real payments; `false` to test with Dodo's test mode and test cards.
    static let dodoLiveMode = true

    static let priceLabel = "₹69"
    static let appName = "Jev Cleaner"

    static var dodoAPIBase: String {
        dodoLiveMode ? "https://live.dodopayments.com" : "https://test.dodopayments.com"
    }

    static var checkoutURL: URL {
        let host = dodoLiveMode ? "checkout.dodopayments.com" : "test.checkout.dodopayments.com"
        return URL(string: "https://\(host)/buy/\(dodoProductID)?quantity=1")!
    }

    static let typesafeConsoleURL = URL(string: "https://console.typesafe.ai/")!
}
