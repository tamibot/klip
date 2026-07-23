import Foundation
import CryptoKit
import Security

/// Encrypts credential text AT REST. The AES-256 key lives in the macOS Keychain (OS-protected, not just
/// file perms), so items.json — and the backup .zip that copies it — never contain credential secrets in
/// the clear. Encryption happens only at the persistence boundary (Storage.save/loadItems); everything in
/// memory keeps working with plaintext. Ciphertext carries a version prefix so older cleartext histories
/// migrate transparently on the next save, and so non-credential text is never touched.
enum CredentialCrypto {
    private static let prefix = "klipenc1:"
    private static let keyAccount = "io.github.tamibot.klip.credentialKey"
    /// The account this key lived under before the bundle id changed. Still read, and adopted into the
    /// current account on the first write: without it every credential sealed by an older Klip would be
    /// permanently unreadable, since the ciphertext is useless without exactly this key.
    private static let legacyKeyAccount = "com.proper.klip.credentialKey"

    /// True if the string is one of our sealed tokens (so we don't double-seal or try to decrypt plaintext).
    static func isSealed(_ s: String) -> Bool { s.hasPrefix(prefix) }

    /// Returns a sealed token for `plaintext`, or nil if encryption is unavailable (caller keeps plaintext).
    static func seal(_ plaintext: String) -> String? {
        guard let key = loadOrCreateKey(),
              let sealed = try? AES.GCM.seal(Data(plaintext.utf8), using: key),
              let combined = sealed.combined else { return nil }
        return prefix + combined.base64EncodedString()
    }

    /// Decrypts a sealed token back to plaintext, or nil if it isn't ours / the key is from another machine.
    static func open(_ token: String) -> String? {
        guard token.hasPrefix(prefix),
              let data = Data(base64Encoded: String(token.dropFirst(prefix.count))),
              let key = loadKey(),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// Ensures the encryption key exists (creating it if absent) WITHOUT returning it. Call OFF the main
    /// thread before a save that may need to seal, so the key's one-time SecItemAdd doesn't run on main.
    static func warmKey() { _ = loadOrCreateKey() }

    // MARK: - Keychain-stored symmetric key

    /// Current account first, then the pre-rename one — an install that predates the bundle id change
    /// still has its key only under the old account, and its sealed items must keep opening.
    private static func loadKey() -> SymmetricKey? {
        readKey(account: keyAccount) ?? readKey(account: legacyKeyAccount)
    }

    private static func readKey(account: String) -> SymmetricKey? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            // NEVER show a blocking Keychain prompt. This read runs during launch (loadItems on the main
            // thread). If the signing identity changed (e.g. an ad-hoc rebuild), the item's ACL no longer
            // trusts us and the DEFAULT behaviour is a modal "Klip wants to use your keychain" dialog that
            // WEDGES the whole app before it ever runs (no menu bar, no poll, no capture). Fail fast instead:
            // open() then returns nil, the sealed token is preserved, and decrypt resumes once a trusting
            // identity is back (a stable signing cert).
            // ponytail: pinned to the deprecated flag on purpose — it is the one remaining build
            // warning. The modern form is an LAContext with interactionNotAllowed passed as
            // kSecUseAuthenticationContext, and it is almost certainly equivalent. "Almost" is the
            // problem: if it is not, the failure is this read blocking on a modal during launch,
            // which is invisible in a test and looks to the user like Klip never started. Migrate
            // when someone can reproduce the untrusted-ACL case (re-sign with a different identity,
            // relaunch, confirm open() still returns nil promptly) — not before.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    /// Serializes loadKey()+SecItemAdd so a concurrent warmKey() (off-main) and saveItems→seal (main) can't
    /// both generate a key and race the insert (which could otherwise diverge or hit errSecDuplicateItem).
    private static let keyLock = NSLock()

    private static func loadOrCreateKey() -> SymmetricKey? {
        keyLock.lock(); defer { keyLock.unlock() }
        if let k = readKey(account: keyAccount) { return k }
        // Adopt the pre-rename key rather than minting a new one: a fresh key would leave every already
        // sealed credential undecryptable. The old item is left in place, so downgrading still works.
        if let legacy = readKey(account: legacyKeyAccount) {
            _ = store(legacy)
            return legacy
        }
        let key = SymmetricKey(size: .bits256)
        return store(key) ? key : loadKey()   // duplicate (another path won the race) or transient → use what's stored
    }

    private static func store(_ key: SymmetricKey) -> Bool {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyAccount,
            kSecValueData as String: key.withUnsafeBytes { Data(Array($0)) },
            // ThisDeviceOnly: available to the background poll, but NOT copied into device/iCloud backups —
            // so the key can't travel to another Mac and decrypt an exported items.json there.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
