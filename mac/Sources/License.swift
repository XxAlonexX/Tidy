import Foundation
import Security

/// The user's own TypeSafe key, kept in the login Keychain.
enum APIKeyStore {
    private static let service = "com.tidyapp.mac.typesafe-api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        // Handy when running a dev build from a shell that already exports the key.
        return ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]
    }

    static func save(_ key: String) {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "default", kSecValueData as String: Data(key.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

enum LicenseError: LocalizedError {
    case notFound, inactive, limitReached, wrongProduct, server(Int)

    var errorDescription: String? {
        switch self {
        case .notFound: return "That license key wasn't found. Check it was copied completely."
        case .inactive: return "That license key is disabled (refunded or revoked)."
        case .limitReached: return "That license key is already active on its maximum number of Macs."
        case .wrongProduct: return "That license key is for a different product."
        case let .server(code): return "Couldn't reach the license server (HTTP \(code)). Try again in a moment."
        }
    }
}

/// Free app with a once-a-day "support us" reminder until a Dodo Payments license is activated.
enum License {
    private static var defaults: UserDefaults { .standard }
    private enum Key {
        static let license = "licenseKey", instance = "licenseInstanceID", email = "licenseEmail"
        static let lastValidated = "licenseLastValidated", lastNag = "lastNagDay", installDay = "installDay"
    }

    static var isLicensed: Bool { defaults.string(forKey: Key.license) != nil }
    static var email: String? { defaults.string(forKey: Key.email) }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Due once per calendar day, starting the day after install so the first launch is about the app, not the ask.
    static var nagDue: Bool {
        if isLicensed { return false }
        let day = today()
        if defaults.string(forKey: Key.installDay) == nil { defaults.set(day, forKey: Key.installDay) }
        if defaults.string(forKey: Key.installDay) == day { return false }
        return defaults.string(forKey: Key.lastNag) != day
    }

    static func markNagShown() { defaults.set(today(), forKey: Key.lastNag) }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: Config.dodoAPIBase + path)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    /// Activates the key for this Mac via Dodo's public endpoint (no merchant API key involved).
    static func activate(_ rawKey: String) async throws -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let machine = Host.current().localizedName ?? "Mac"
        let (code, json) = try await post("/licenses/activate", ["license_key": key, "name": machine])
        switch code {
        case 200, 201: break
        case 404: throw LicenseError.notFound
        case 403: throw LicenseError.inactive
        case 422: throw LicenseError.limitReached
        default: throw LicenseError.server(code)
        }
        let productID = (json["product"] as? [String: Any])?["product_id"] as? String
        if let productID, productID != Config.dodoProductID {
            if let instance = json["id"] as? String {
                _ = try? await post("/licenses/deactivate", ["license_key": key, "license_key_instance_id": instance])
            }
            throw LicenseError.wrongProduct
        }
        let email = (json["customer"] as? [String: Any])?["email"] as? String
        defaults.set(key, forKey: Key.license)
        defaults.set(json["id"] as? String, forKey: Key.instance)
        defaults.set(email, forKey: Key.email)
        defaults.set(Date(), forKey: Key.lastValidated)
        return email
    }

    /// Weekly check that the license wasn't refunded or revoked. Network trouble never un-licenses anyone.
    static func revalidateIfStale() async {
        guard let key = defaults.string(forKey: Key.license) else { return }
        if let last = defaults.object(forKey: Key.lastValidated) as? Date, Date().timeIntervalSince(last) < 7 * 86_400 { return }
        var body: [String: Any] = ["license_key": key]
        if let instance = defaults.string(forKey: Key.instance) { body["license_key_instance_id"] = instance }
        guard let (code, json) = try? await post("/licenses/validate", body), code == 200 else { return }
        if json["valid"] as? Bool == false {
            for k in [Key.license, Key.instance, Key.email] { defaults.removeObject(forKey: k) }
        } else {
            defaults.set(Date(), forKey: Key.lastValidated)
        }
    }
}
