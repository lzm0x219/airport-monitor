import CryptoKit
import Foundation

guard let input = readLine(), let seed = Data(base64Encoded: input), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write(Data("Invalid update signing key.\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
