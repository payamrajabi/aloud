import Foundation
import CryptoKit

struct Fixtures: Decodable {
    let publicKey: String
    let live: String
    let test: String
    let testSameSigner: String
    let invalid: [String: String]
}

var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(name)") }
}

let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: fixtures.publicKey)!)
let live = LicensePolicy.verify(fixtures.live, publicKey: publicKey)
check(live?.email == "buyer+test@example.com", "JS-issued live key verifies in CryptoKit")
check(LicensePolicy.verify(fixtures.test, publicKey: publicKey) == nil, "production mode rejects JS sandbox key")
check(LicensePolicy.verify(fixtures.testSameSigner, publicKey: publicKey) == nil, "production rejects test mode even with the same signing key")
check(LicensePolicy.verify(fixtures.test, publicKey: publicKey, expectedMode: .test)?.mode == .test, "injected sandbox mode interoperates")
check(LicensePolicy.verify(fixtures.live, publicKey: publicKey, expectedMode: .test) == nil, "sandbox harness rejects live mode")
let wrongKey = Curve25519.Signing.PrivateKey().publicKey
check(LicensePolicy.verify(fixtures.live, publicKey: wrongKey) == nil, "wrong public key")
for (name, key) in fixtures.invalid.sorted(by: { $0.key < $1.key }) {
    check(LicensePolicy.verify(key, publicKey: publicKey) == nil, "reject \(name)")
}

let key = fixtures.live
let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
let accepted = [
    key, " \n\(key)\r\n",
    "aloud://activate?license=\(key)",
    "aloud://activate?source=email&license=\(key)&tracking=extra",
    "aloud://activate?license=\(encodedKey)&next=ignored",
    "https://aloudformac.com/activate#\(key)",
    "https://aloudformac.com/activate?source=email#\(key)",
]
for text in accepted { check(LicensePolicy.extractKey(from: text) == key, "activation accepts \(text.prefix(45))") }
let rejected = [
    "", "prefix \(key)", "\(key) trailing", "https://evil.example/activate#\(key)",
    "http://aloudformac.com/activate#\(key)", "https://aloudformac.com/other#\(key)",
    "https://aloudformac.com.evil.example/activate#\(key)",
    "https://user@aloudformac.com/activate#\(key)",
    "aloud://activate?license=\(key)&license=\(key)",
    "aloud://activate?license=bad&extra=\(key)", "aloud://activate?other=\(key)",
    "aloud://activate?license=", "aloud://activate/path?license=\(key)",
    "aloud://activate?license=\(key)#extra", "aloud://other?license=\(key)",
    "aloud://activate:123?license=\(key)", "\(key).extra",
]
for text in rejected { check(LicensePolicy.extractKey(from: text) == nil, "activation rejects \(text.prefix(45))") }

let start = Date(timeIntervalSince1970: 1_791_504_000)
let fresh = LicensePolicy.initializeTrial(started: nil, hasTrialMarker: false, earlyUser: false,
    wasWelcomed: false, wasOfferedLoginItem: false, now: start)
check(fresh == LicensePolicy.Trial(started: start, earlyUser: false), "fresh paid install starts one trial")
for legacy in [(true, false), (false, true)] {
    let old = LicensePolicy.initializeTrial(started: nil, hasTrialMarker: false, earlyUser: false,
        wasWelcomed: legacy.0, wasOfferedLoginItem: legacy.1, now: start)
    check(old.earlyUser, "welcome/login legacy marker keeps free users free")
    check(LicensePolicy.status(license: nil, trial: old, now: start.addingTimeInterval(30 * 86_400)) == .earlyUser,
          "legacy entitlement survives trial expiry")
}
let relaunched = LicensePolicy.initializeTrial(started: start, hasTrialMarker: true, earlyUser: false,
    wasWelcomed: true, wasOfferedLoginItem: true, now: start.addingTimeInterval(8 * 86_400))
check(relaunched == fresh, "paid welcome/login markers do not grandfather a paid reinstall")
let malformed = LicensePolicy.initializeTrial(started: nil, hasTrialMarker: true, earlyUser: false,
    wasWelcomed: true, wasOfferedLoginItem: true, now: start)
check(LicensePolicy.status(license: nil, trial: malformed, now: start) == .expired, "malformed existing trial cannot restart or grandfather")
for (elapsed, expected) in [(0.0, 7), (86_399.0, 7), (86_400.0, 6), (6 * 86_400.0, 1), (7 * 86_400.0 - 0.01, 1)] {
    check(LicensePolicy.status(license: nil, trial: fresh, now: start.addingTimeInterval(elapsed)) == .trial(daysLeft: expected),
          "trial boundary \(elapsed)")
}
check(LicensePolicy.status(license: nil, trial: fresh, now: start.addingTimeInterval(7 * 86_400)) == .expired, "expires at exactly 7 elapsed days")
check(LicensePolicy.status(license: nil, trial: fresh, now: start.addingTimeInterval(9 * 86_400)) == .expired, "remains expired")
check(LicensePolicy.status(license: nil, trial: fresh, now: start.addingTimeInterval(-100)) == .trial(daysLeft: 7), "clock rollback does not add days beyond the original week")
check(LicensePolicy.status(license: live, trial: fresh, now: start.addingTimeInterval(100 * 86_400)) == .licensed(email: "buyer+test@example.com"), "license unlocks expired trial offline")
check(LicensePolicy.status(license: nil, trial: fresh, now: start.addingTimeInterval(100 * 86_400)) == .expired, "removing license does not restart trial")
check(LicensePolicy.status(license: live, trial: LicensePolicy.Trial(started: start, earlyUser: true), now: start) == .licensed(email: "buyer+test@example.com"), "licensed status precedes legacy status")

print("Licensing: \(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
