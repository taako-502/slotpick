import CryptoKit
import Foundation

// Verify against the public key embedded in the app, including on CI.
let arguments = CommandLine.arguments
guard arguments.count == 4,
    let key = Data(base64Encoded: arguments[1]),
    let signature = Data(base64Encoded: arguments[2])
else { fatalError("Invalid update verification arguments") }
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
guard publicKey.isValidSignature(signature, for: archive) else {
    fatalError("Update signature does not match the application's public key")
}
