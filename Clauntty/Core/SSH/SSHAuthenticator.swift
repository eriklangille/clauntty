import Foundation
import NIOCore
import NIOSSH
import Crypto

/// Handles SSH authentication (password and SSH key)
class SSHAuthenticator: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let authMethod: AuthMethod
    private let connectionId: UUID

    private var triedPassword = false
    private var triedKey = false

    init(username: String, authMethod: AuthMethod, connectionId: UUID) {
        self.username = username
        self.authMethod = authMethod
        self.connectionId = connectionId
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        switch authMethod {
        case .password:
            guard availableMethods.contains(.password), !triedPassword else {
                // No more auth methods to try
                nextChallengePromise.succeed(nil)
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
                    nextChallengePromise.succeed(nil)
                }
            }

        case .sshKey(let keyId):
            guard availableMethods.contains(.publicKey), !triedKey else {
                nextChallengePromise.succeed(nil)
                return
            }

            triedKey = true

            Task { @MainActor in
                do {
                    let privateKey = try self.loadPrivateKey(keyId: keyId)

                    let offer = NIOSSHUserAuthenticationOffer(
                        username: self.username,
                        serviceName: "ssh-connection",
                        offer: .privateKey(.init(privateKey: privateKey))
                    )
                    nextChallengePromise.succeed(offer)
                } catch {
                    print("Failed to load SSH key: \(error)")
                    nextChallengePromise.succeed(nil)
                }
            }
        }
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
        // OpenSSH private key format parsing
        // This is a simplified implementation - production code should use a proper parser

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
        // Format: "openssh-key-v1\0" + cipher + kdf + kdfOptions + numKeys + pubkey + privkey

        // For now, only support unencrypted keys
        // TODO: Implement encrypted key support with passphrase

        // This is a placeholder - proper implementation requires parsing the binary format
        // For Ed25519 keys:
        // let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKeyBytes)
        // return NIOSSHPrivateKey(ed25519Key: ed25519Key)

        throw AuthError.unsupportedKeyFormat("OpenSSH key parsing not yet implemented")
    }

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
