// 업데이트 ZIP의 EdDSA 서명이 앱 Info.plist의 SUPublicEDKey와 맞는지 확인해요.
// usage: swift tools/verify_update_sig.swift <SUPublicEDKey(base64)> <archive> <edSignature(base64)>
import CryptoKit
import Foundation

let a = CommandLine.arguments
guard a.count == 4,
      let pub = Data(base64Encoded: a[1]),
      let sig = Data(base64Encoded: a[3]),
      let file = FileManager.default.contents(atPath: a[2]) else {
    FileHandle.standardError.write("usage: verify_update_sig.swift <public-key> <archive> <signature>\n".data(using: .utf8)!)
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: pub)
    if key.isValidSignature(sig, for: file) { print("signature OK"); exit(0) }
    FileHandle.standardError.write("signature does NOT match SUPublicEDKey\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("bad public key: \(error)\n".data(using: .utf8)!)
    exit(2)
}
