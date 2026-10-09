import Foundation
import CryptoKit

/// Pure rules shared by the app and the standalone licensing tests. No storage, UI or network access.
enum LicensePolicy {
    static let trialDays = 7

    enum Mode: String, Decodable { case live, test }

    struct License: Decodable, Equatable {
        let product: String
        let mode: Mode
        let email: String
        let id: String
        let issued: String
    }

    enum Status: Equatable {
        case licensed(email: String)
        case earlyUser
        case trial(daysLeft: Int)
        case expired
    }

    struct Trial: Equatable {
        let started: Date?
        let earlyUser: Bool
    }

    /// Only an absent trial marker may grandfather a previous free install. A paid install's
    /// later welcome/login flags must never turn its expired trial into an early-user entitlement.
    static func initializeTrial(started: Date?, hasTrialMarker: Bool, earlyUser: Bool,
                                wasWelcomed: Bool, wasOfferedLoginItem: Bool, now: Date) -> Trial {
        if hasTrialMarker { return Trial(started: started, earlyUser: earlyUser) }
        return Trial(started: now, earlyUser: earlyUser || wasWelcomed || wasOfferedLoginItem)
    }

    static func status(license: License?, trial: Trial, now: Date, earlyUsersFree: Bool = true) -> Status {
        if let license { return .licensed(email: license.email) }
        if earlyUsersFree, trial.earlyUser { return .earlyUser }
        guard let start = trial.started else { return .expired }
        let elapsed = max(0, now.timeIntervalSince(start))
        guard elapsed < Double(trialDays) * 86_400 else { return .expired }
        return .trial(daysLeft: trialDays - Int(elapsed / 86_400))
    }

    /// The signature covers the exact JSON bytes. The app always requests live licenses;
    /// tests inject an ephemeral public key and explicitly request sandbox mode.
    static func verify(_ key: String, publicKey: Curve25519.Signing.PublicKey,
                       expectedMode: Mode = .live) -> License? {
        guard key.utf8.count <= 8_192 else { return nil }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Data(base64URL: parts[0]), payload.count <= 4_096,
              let signature = Data(base64URL: parts[1]), signature.count == 64,
              publicKey.isValidSignature(signature, for: payload),
              let license = try? JSONDecoder().decode(License.self, from: payload),
              license.product == "aloud", license.mode == expectedMode,
              validEmail(license.email),
              license.id.range(of: "^cs_" + expectedMode.rawValue + "_[A-Za-z0-9]+$", options: .regularExpression) != nil,
              validDay(license.issued)
        else { return nil }
        return license
    }

    private static func validEmail(_ email: String) -> Bool {
        guard email.utf8.count <= 254, !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return email.range(of: "^[^\\s@<>]+@[^\\s@<>]+\\.[^\\s@<>]+$", options: .regularExpression) != nil
    }

    private static func validDay(_ day: String) -> Bool {
        guard day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: day) else { return false }
        return formatter.string(from: date) == day
    }

    /// Accept exactly a raw key or a supported activation URL. Query items are parsed by
    /// name, so appended tracking parameters cannot become the key; duplicate keys are rejected.
    static func extractKey(from text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isKeyShape(text) { return text }
        guard let url = URLComponents(string: text), url.user == nil, url.password == nil,
              url.port == nil else { return nil }
        if url.scheme?.lowercased() == "aloud", url.host?.lowercased() == "activate",
           url.path.isEmpty || url.path == "/", url.fragment == nil {
            let keys = (url.queryItems ?? []).filter { $0.name == "license" }
            guard keys.count == 1, let key = keys[0].value, isKeyShape(key) else { return nil }
            return key
        }
        if url.scheme?.lowercased() == "https", url.host?.lowercased() == "aloudformac.com",
           url.path == "/activate", let key = url.fragment, isKeyShape(key) {
            return key
        }
        return nil
    }

    static func isActivationURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "aloud" && url.host?.lowercased() == "activate"
    }

    private static func isKeyShape(_ key: String) -> Bool {
        key.utf8.count <= 8_192 && key.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

private extension Data {
    init?(base64URL: Substring) {
        guard !base64URL.isEmpty,
              base64URL.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let decoded = Data(base64Encoded: text),
              decoded.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == String(base64URL)
        else { return nil }
        self = decoded
    }
}

// The harness compiles the production policy above without initializing the AppKit adapter.
#if !LICENSING_TESTS
import AppKit

/// The free week and the license. Aloud is free for 7 days from the first launch of a
/// paid version, then a one-time purchase unlocks it for good. Licenses are signed on
/// aloudformac.com and checked here, offline, so nothing phones home.
final class Licensing: ObservableObject {
    static let shared = Licensing()

    typealias Status = LicensePolicy.Status

    @Published private(set) var status: Status = .expired

    static let trialDays = LicensePolicy.trialDays
    /// People who installed Aloud while it was free keep it free.
    static let earlyUsersFree = true
    static let buyURL = URL(string: "https://aloudformac.com/buy")!
    static let restoreURL = URL(string: "https://aloudformac.com/restore")!

    /// The public half of the key that signs licenses on aloudformac.com.
    private static let publicKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(base64Encoded: "Jloz1nv3RGWcn3FDnpYmymCeF7fku8q9H3Rqx6giMp4=")!)

    private static let licenseKey = "license"
    private static let trialStartKey = "trialStarted"
    private static let earlyUserKey = "earlyUser"
    #if DEBUG
    /// Debug builds only: pretend the trial started on this day, ignoring early-user status.
    private static let trialStartOverride = ProcessInfo.processInfo.environment["ALOUD_TRIAL_START"]
        .flatMap { ISO8601DateFormatter.date(fromDay: $0) }
    #else
    private static let trialStartOverride: Date? = nil
    #endif

    private var isShowingAlert = false

    /// Create this before anything sets "didWelcome", so a brand-new install isn't mistaken for an early user.
    private init() {
        let defaults = UserDefaults.standard
        let marker = defaults.object(forKey: Self.trialStartKey)
        if marker == nil {
            let trial = LicensePolicy.initializeTrial(started: nil, hasTrialMarker: false,
                earlyUser: defaults.bool(forKey: Self.earlyUserKey),
                wasWelcomed: defaults.bool(forKey: "didWelcome"),
                wasOfferedLoginItem: defaults.bool(forKey: "didOfferLoginItem"), now: Date())
            defaults.set(trial.earlyUser, forKey: Self.earlyUserKey)
            defaults.set(trial.started, forKey: Self.trialStartKey)
        }
        refresh()
    }

    /// Re-reads the license and the clock (the trial runs out while the app is open).
    func refresh() {
        let defaults = UserDefaults.standard
        let license = defaults.string(forKey: Self.licenseKey).flatMap(Self.verify)
        let trial = LicensePolicy.Trial(
            started: Self.trialStartOverride ?? defaults.object(forKey: Self.trialStartKey) as? Date,
            earlyUser: Self.trialStartOverride == nil && defaults.bool(forKey: Self.earlyUserKey))
        let new = LicensePolicy.status(license: license, trial: trial, now: Date(), earlyUsersFree: Self.earlyUsersFree)
        if new != status { status = new }
    }

    var isUnlocked: Bool {
        refresh()
        return status != .expired
    }

    /// Reading and dictation call this first. Once the trial is over it explains and offers to buy.
    func allowUse() -> Bool {
        if isUnlocked { return true }
        showExpired()
        return false
    }

    // MARK: - Licenses

    typealias License = LicensePolicy.License

    /// A license is base64url(JSON) + "." + base64url(Ed25519 signature of that JSON).
    static func verify(_ key: String) -> License? {
        LicensePolicy.verify(key, publicKey: publicKey, expectedMode: .live)
    }

    /// Accepts the raw key or an activation link from Aloud's website or purchase email.
    static func extractKey(from text: String) -> String {
        LicensePolicy.extractKey(from: text) ?? ""
    }

    @discardableResult
    func activate(_ text: String) -> Bool {
        let key = Self.extractKey(from: text)
        guard Self.verify(key) != nil else { return false }
        UserDefaults.standard.set(key, forKey: Self.licenseKey)
        refresh()
        return true
    }

    func removeLicense() {
        UserDefaults.standard.removeObject(forKey: Self.licenseKey)
        refresh()
    }

    /// aloud://activate?license=…, opened by the thank-you page or the link in the email.
    func handle(_ url: URL) {
        guard LicensePolicy.isActivationURL(url) else { return }
        if activate(url.absoluteString) {
            alert("Aloud is unlocked", "Thanks for buying Aloud! Reading and dictation are yours to keep, on all your Macs.")
        } else {
            alert("That license didn't work", "Try the link in your purchase email again, or paste the license in Aloud Settings.")
        }
    }

    // MARK: - Prompts

    func buy() { NSWorkspace.shared.open(Self.buyURL) }

    func restore() { NSWorkspace.shared.open(Self.restoreURL) }

    func showExpired() {
        guard !isShowingAlert else { return }
        isShowingAlert = true
        defer { isShowingAlert = false }
        NSApp.activate(ignoringOtherApps: true)
        switch Self.expiredAlert().runModal() {
        case .alertFirstButtonReturn: buy()
        case .alertSecondButtonReturn: promptForLicense()
        default: break
        }
    }

    static func expiredAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Your free week of Aloud is over"
        alert.informativeText = "Buy Aloud once to keep reading and dictating, on all your Macs. No subscription."
        alert.addButton(withTitle: "Buy Aloud…")
        alert.addButton(withTitle: "Enter License…")
        alert.addButton(withTitle: "Not Now")
        return alert
    }

    func promptForLicense() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enter your Aloud license"
        alert.informativeText = "Paste the license from your purchase email."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "License"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Find My License…")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if activate(field.stringValue) {
                self.alert("Aloud is unlocked", "Thanks for buying Aloud!")
            } else {
                self.alert("That license didn't work", "Copy the whole license from your purchase email and try again.")
            }
        case .alertThirdButtonReturn: restore()
        default: break
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// For the menu: "Free Trial: 3 Days Left", or nil once there's nothing to say.
    var menuTitle: String? {
        switch status {
        case .trial(let days): return "Free Trial: \(days) \(days == 1 ? "Day" : "Days") Left"
        case .expired: return "Free Trial Ended"
        case .licensed, .earlyUser: return nil
        }
    }
}

private extension ISO8601DateFormatter {
    static func date(fromDay day: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: day)
    }
}
#endif
