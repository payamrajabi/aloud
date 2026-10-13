import AppKit
import CryptoKit

/// The free week and the license. Aloud is free for 7 days from the first launch of a
/// paid version, then a one-time purchase unlocks it for good. Licenses are signed on
/// aloudformac.com and checked here, offline, so nothing phones home.
final class Licensing: ObservableObject {
    static let shared = Licensing()

    enum Status: Equatable {
        case licensed(email: String)
        /// Installed Aloud while it was free, so it stays free for them.
        case earlyUser
        case trial(daysLeft: Int)
        case expired
    }

    @Published private(set) var status: Status = .expired

    static let trialDays = 7
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
    /// Testing: ALOUD_TRIAL_START=2026-10-01 pretends the trial started then (and ignores early-user status).
    private static let trialStartOverride = ProcessInfo.processInfo.environment["ALOUD_TRIAL_START"]
        .flatMap { ISO8601DateFormatter.date(fromDay: $0) }

    private var isShowingAlert = false

    /// Create this before anything sets "didWelcome", so a brand-new install isn't mistaken for an early user.
    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.trialStartKey) == nil {
            // Seen the welcome, or been offered the login item, in an earlier version: an early user.
            if defaults.bool(forKey: "didWelcome") || defaults.bool(forKey: "didOfferLoginItem") {
                defaults.set(true, forKey: Self.earlyUserKey)
            }
            defaults.set(Date(), forKey: Self.trialStartKey)
        }
        refresh()
    }

    /// Re-reads the license and the clock (the trial runs out while the app is open).
    func refresh() {
        let defaults = UserDefaults.standard
        let new: Status
        if let key = defaults.string(forKey: Self.licenseKey), let license = Self.verify(key) {
            new = .licensed(email: license.email)
        } else if Self.earlyUsersFree, Self.trialStartOverride == nil, defaults.bool(forKey: Self.earlyUserKey) {
            new = .earlyUser
        } else {
            let start = Self.trialStartOverride ?? defaults.object(forKey: Self.trialStartKey) as? Date ?? Date()
            let daysUsed = Int(max(0, Date().timeIntervalSince(start)) / 86_400)
            new = daysUsed < Self.trialDays ? .trial(daysLeft: Self.trialDays - daysUsed) : .expired
        }
        if new != status { status = new }
    }

    var isUnlocked: Bool {
        if DebugScript.isActive { return true }
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

    struct License: Decodable {
        let product: String
        let email: String
        let id: String
    }

    /// A license is base64url(JSON) + "." + base64url(Ed25519 signature of that JSON).
    static func verify(_ key: String) -> License? {
        let parts = key.split(separator: ".")
        guard parts.count == 2, let payload = Data(base64URL: parts[0]), let signature = Data(base64URL: parts[1]),
              publicKey.isValidSignature(signature, for: payload),
              let license = try? JSONDecoder().decode(License.self, from: payload), license.product == "aloud"
        else { return nil }
        return license
    }

    /// Accepts the key itself or anything that ends with it, such as the activation link from the email.
    static func extractKey(from text: String) -> String {
        text.split(whereSeparator: { "=#/?& \n\r\t".contains($0) }).last.map(String.init) ?? ""
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
        guard url.scheme == "aloud", url.host == "activate" else { return }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "license" })?.value ?? ""
        if activate(key) {
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

private extension Data {
    init?(base64URL: Substring) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}

private extension ISO8601DateFormatter {
    static func date(fromDay day: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: day)
    }
}
