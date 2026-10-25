import Foundation
import NIOCore
import NIOSSH
import Crypto
import os.log

/// Handles SSH authentication (password and SSH key). Used on its connection's event
/// loop; `gaveUp` is read once the connection has closed.
final class SSHAuthenticator: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let authMethod: AuthMethod
    private let connectionId: UUID

    private var triedPassword = false
    private var triedKey = false
    private var triedNone = false
    /// Every method was refused. NIOSSH only marks the attempt failed; the connection
    /// stays open and its channels wait forever, so the connection closes itself.
    private(set) var gaveUp = false
    private let onGiveUp: () -> Void

    init(username: String, authMethod: AuthMethod, connectionId: UUID, onGiveUp: @escaping () -> Void = {}) {
        self.username = username
        self.authMethod = authMethod
        self.connectionId = connectionId
        self.onGiveUp = onGiveUp
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        Logger.clauntty.debugOnly("SSH auth: nextAuthenticationType called, availableMethods=\(String(describing: availableMethods))")

        switch authMethod {
        case .password:
            guard availableMethods.contains(.password), !triedPassword else {
                // No more auth methods to try
                offerNoneOrGiveUp(nextChallengePromise)
                return
            }

            triedPassword = true

            // Get password from Keychain
            // This is called from NIO thread, so we need to handle async carefully
            Task { @MainActor in
                do {
                    // In a real implementation, you'd pass the connection ID
                    // For now, we'll assume password is already loaded
                    let password = try self.getStoredPassword()

                    let offer = NIOSSHUserAuthenticationOffer(
                        username: self.username,
                        serviceName: "ssh-connection",
                        offer: .password(.init(password: password))
                    )
                    nextChallengePromise.succeed(offer)
                } catch {
                    self.offerNoneOrGiveUp(nextChallengePromise)
                }
            }

        case .sshKey(let keyId):
            Logger.clauntty.debugOnly("SSH auth: trying publicKey, available=\(availableMethods.contains(.publicKey)), triedKey=\(self.triedKey)")
            guard availableMethods.contains(.publicKey), !triedKey else {
                Logger.clauntty.debugOnly("SSH auth: no more methods to try")
                offerNoneOrGiveUp(nextChallengePromise)
                return
            }

            triedKey = true

            Task { @MainActor in
                do {
                    Logger.clauntty.debugOnly("SSH auth: loading private key \(keyId.prefix(8))...")
                    let privateKey = try self.loadPrivateKey(keyId: keyId)
                    Logger.clauntty.debugOnly("SSH auth: key loaded, sending offer for user '\(self.username)'")

                    let offer = NIOSSHUserAuthenticationOffer(
                        username: self.username,
                        serviceName: "ssh-connection",
                        offer: .privateKey(.init(privateKey: privateKey))
                    )
                    nextChallengePromise.succeed(offer)
                    Logger.clauntty.debugOnly("SSH auth: offer sent")
                } catch {
                    Logger.clauntty.error("SSH auth: failed to load SSH key: \(error.localizedDescription)")
                    self.offerNoneOrGiveUp(nextChallengePromise)
                }
            }
        }
    }

    /// Last resort, once: the "none" method. Tailscale SSH lets a device on the
    /// tailnet in with it (no password or key: the tailnet identity is the
    /// credential); any other server just refuses it.
    private func offerNoneOrGiveUp(_ promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !triedNone else {
            gaveUp = true
            promise.succeed(nil)
            onGiveUp()
            return
        }
        triedNone = true
        Logger.clauntty.debugOnly("SSH auth: trying none")
        promise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "ssh-connection", offer: .none))
    }

    // MARK: - Credential Loading

    private func getStoredPassword() throws -> String {
        // Load password from Keychain using the connection ID
        guard let password = try? KeychainHelper.getPassword(for: connectionId) else {
            throw AuthError.passwordNotFound
        }
        return password
    }

    private func loadPrivateKey(keyId: String) throws -> NIOSSHPrivateKey {
        // The Mac app uses the key files ~/.ssh/config names, not keys imported into the Keychain
        if keyId.hasPrefix(Self.keyFilePrefix) {
            let path = String(keyId.dropFirst(Self.keyFilePrefix.count))
            guard let data = FileManager.default.contents(atPath: path) else {
                throw AuthError.keyNotFound
            }
            return try parsePrivateKey(data: data, passphrase: nil)
        }

        // Load key data from Keychain
        guard let keyInfo = try KeychainHelper.getSSHKey(id: keyId) else {
            throw AuthError.keyNotFound
        }

        let privateKeyData = keyInfo.privateKey

        // Parse the private key
        // SwiftNIO SSH supports Ed25519, ECDSA (P-256, P-384, P-521), and RSA
        return try parsePrivateKey(data: privateKeyData, passphrase: keyInfo.passphrase)
    }

    private func parsePrivateKey(data: Data, passphrase: String?) throws -> NIOSSHPrivateKey {
        let keyString = String(data: data, encoding: .utf8) ?? ""

        // Detect key type from header
        if keyString.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHKey(data: data, passphrase: passphrase)
        } else if keyString.contains("BEGIN RSA PRIVATE KEY") {
            throw AuthError.unsupportedKeyFormat("PEM RSA keys not yet supported")
        } else if keyString.contains("BEGIN EC PRIVATE KEY") {
            throw AuthError.unsupportedKeyFormat("PEM EC keys not yet supported")
        } else {
            throw AuthError.unsupportedKeyFormat("Unknown key format")
        }
    }

    private func parseOpenSSHKey(data: Data, passphrase: String?) throws -> NIOSSHPrivateKey {
        let keyString = String(data: data, encoding: .utf8) ?? ""
        let lines = keyString.components(separatedBy: .newlines)

        // Find the base64 content between headers
        var base64Content = ""
        var inKey = false
        for line in lines {
            if line.contains("BEGIN OPENSSH PRIVATE KEY") {
                inKey = true
                continue
            }
            if line.contains("END OPENSSH PRIVATE KEY") {
                break
            }
            if inKey {
                base64Content += line.trimmingCharacters(in: .whitespaces)
            }
        }

        guard let keyData = Data(base64Encoded: base64Content) else {
            throw AuthError.invalidKeyData
        }

        // Parse the OpenSSH key format
        var reader = OpenSSHKeyReader(data: keyData)

        // Check magic header "openssh-key-v1\0"
        let magic = "openssh-key-v1\0"
        guard let headerData = reader.readBytes(magic.count),
              String(data: headerData, encoding: .utf8) == magic else {
            throw AuthError.invalidKeyData
        }

        // Read cipher name
        guard let cipherName = reader.readString() else {
            throw AuthError.invalidKeyData
        }

        // Read KDF name
        guard let kdfName = reader.readString() else {
            throw AuthError.invalidKeyData
        }

        // Read KDF options (we'll skip this for unencrypted keys)
        guard let _ = reader.readLengthPrefixedData() else {
            throw AuthError.invalidKeyData
        }

        // Number of keys
        guard let numKeys = reader.readUInt32(), numKeys == 1 else {
            throw AuthError.unsupportedKeyFormat("Only single-key files supported")
        }

        // Read public key (length-prefixed, we skip it)
        guard let _ = reader.readLengthPrefixedData() else {
            throw AuthError.invalidKeyData
        }

        // Read private key section (length-prefixed)
        guard let privateKeyData = reader.readLengthPrefixedData() else {
            throw AuthError.invalidKeyData
        }

        // Check if encrypted
        if cipherName != "none" || kdfName != "none" {
            if passphrase == nil {
                throw AuthError.unsupportedKeyFormat("Encrypted keys require passphrase")
            }
            throw AuthError.unsupportedKeyFormat("Encrypted keys not yet supported")
        }

        // Parse the private key section
        var privReader = OpenSSHKeyReader(data: privateKeyData)

        // Two check integers (must match)
        guard let check1 = privReader.readUInt32(),
              let check2 = privReader.readUInt32(),
              check1 == check2 else {
            throw AuthError.invalidKeyData
        }

        // Key type string
        guard let keyType = privReader.readString() else {
            throw AuthError.invalidKeyData
        }

        // Parse based on key type
        switch keyType {
        case "ssh-ed25519":
            // Public key (32 bytes)
            guard let _ = privReader.readLengthPrefixedData() else {
                throw AuthError.invalidKeyData
            }

            // Private key: 64 bytes (32 byte seed + 32 byte public key copy)
            guard let privateKeyBytes = privReader.readLengthPrefixedData(),
                  privateKeyBytes.count == 64 else {
                throw AuthError.invalidKeyData
            }

            // The first 32 bytes are the seed (private key)
            let seed = privateKeyBytes.prefix(32)
            let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return NIOSSHPrivateKey(ed25519Key: ed25519Key)

        case "ecdsa-sha2-nistp256":
            // ECDSA P-256: public key + private key scalar
            guard let _ = privReader.readString() else {  // curve name "nistp256"
                throw AuthError.invalidKeyData
            }
            guard let _ = privReader.readLengthPrefixedData() else {  // public key
                throw AuthError.invalidKeyData
            }
            guard let privateKeyBytes = privReader.readLengthPrefixedData() else {
                throw AuthError.invalidKeyData
            }
            let p256Key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
            return NIOSSHPrivateKey(p256Key: p256Key)

        case "ecdsa-sha2-nistp384":
            guard let _ = privReader.readString() else {
                throw AuthError.invalidKeyData
            }
            guard let _ = privReader.readLengthPrefixedData() else {
                throw AuthError.invalidKeyData
            }
            guard let privateKeyBytes = privReader.readLengthPrefixedData() else {
                throw AuthError.invalidKeyData
            }
            let p384Key = try P384.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
            return NIOSSHPrivateKey(p384Key: p384Key)

        case "ecdsa-sha2-nistp521":
            guard let _ = privReader.readString() else {
                throw AuthError.invalidKeyData
            }
            guard let _ = privReader.readLengthPrefixedData() else {
                throw AuthError.invalidKeyData
            }
            guard let privateKeyBytes = privReader.readLengthPrefixedData() else {
                throw AuthError.invalidKeyData
            }
            let p521Key = try P521.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
            return NIOSSHPrivateKey(p521Key: p521Key)

        default:
            throw AuthError.unsupportedKeyFormat("Key type '\(keyType)' not supported. Use Ed25519 or ECDSA.")
        }
    }

    /// A key ID that names a key file instead of a Keychain entry: `file:/path/to/key`
    static let keyFilePrefix = "file:"

    enum AuthError: Error, LocalizedError {
        case passwordNotFound
        case keyNotFound
        case invalidKeyData
        case unsupportedKeyFormat(String)
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .passwordNotFound:
                return "Password not found in Keychain"
            case .keyNotFound:
                return "SSH key not found in Keychain"
            case .invalidKeyData:
                return "Invalid SSH key data"
            case .unsupportedKeyFormat(let format):
                return "Unsupported key format: \(format)"
            case .decryptionFailed:
                return "Failed to decrypt SSH key"
            }
        }
    }
}

// MARK: - OpenSSH Key Reader Helper

private struct OpenSSHKeyReader {
    private var data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard offset + count <= data.count else { return nil }
        let result = data[offset..<offset+count]
        offset += count
        return Data(result)
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    mutating func readString() -> String? {
        guard let data = readLengthPrefixedData() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    mutating func readLengthPrefixedData() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(Int(length))
    }
}

// MARK: - OpenSSH Key Files

/// Keys made in the app, and the public half of any OpenSSH private key file, as a line
/// for `authorized_keys`
enum OpenSSHKeyFile {
    /// A new Ed25519 key as an unencrypted OpenSSH private key file
    static func generateEd25519(comment: String) -> Data {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        let publicBlob = string("ssh-ed25519") + string(pub)

        let check = UInt32.random(in: .min ... .max)
        var secret = uint32(check) + uint32(check)
        secret += string("ssh-ed25519") + string(pub)
        secret += string(key.rawRepresentation + pub)
        secret += string(Data(comment.utf8))
        var pad: UInt8 = 1
        while secret.count % 8 != 0 {
            secret.append(pad)
            pad += 1
        }

        var file = Data("openssh-key-v1\0".utf8)
        file += string("none") + string("none") + string(Data())
        file += uint32(1) + string(publicBlob) + string(secret)

        let body = file.base64EncodedString()
        let lines = stride(from: 0, to: body.count, by: 70).map { start -> String in
            let from = body.index(body.startIndex, offsetBy: start)
            return String(body[from..<(body.index(from, offsetBy: 70, limitedBy: body.endIndex) ?? body.endIndex)])
        }
        let pem = (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----", ""])
            .joined(separator: "\n")
        return Data(pem.utf8)
    }

    /// "ssh-ed25519 AAAA… comment": the public key an OpenSSH private key file carries in
    /// the clear, encrypted or not
    static func publicKeyLine(privateKey data: Data, comment: String? = nil) -> String? {
        let text = String(data: data, encoding: .utf8) ?? ""
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { return nil }
        let body = text.components(separatedBy: .newlines)
            .filter { !$0.contains("OPENSSH PRIVATE KEY") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        guard let file = Data(base64Encoded: body) else { return nil }

        var reader = OpenSSHKeyReader(data: file)
        guard let magic = reader.readBytes(15), magic == Data("openssh-key-v1\0".utf8),
              reader.readString() != nil, reader.readString() != nil,
              reader.readLengthPrefixedData() != nil,
              reader.readUInt32() == 1,
              let blob = reader.readLengthPrefixedData() else { return nil }
        var blobReader = OpenSSHKeyReader(data: blob)
        guard let type = blobReader.readString() else { return nil }
        return [type, blob.base64EncodedString(), comment].compactMap { $0 }.joined(separator: " ")
    }

    /// A shell line that adds `publicKey` to the server's `authorized_keys`
    static func setupCommand(publicKey: String) -> String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(publicKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    private static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func string(_ value: String) -> Data {
        string(Data(value.utf8))
    }

    private static func string(_ value: Data) -> Data {
        uint32(UInt32(value.count)) + value
    }
}
