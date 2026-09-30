// Checks an Ed25519 signature: swift scripts/lib/ed25519-verify.swift
// <public-key-base64> <signature-base64> <file>. Exit 0 when the signature is
// valid for the file under that public key, 1 when it is not, 2 on bad usage.
// make-appcast.sh uses it to prove that a new appcast item was signed by the
// release key (SUPublicEDKey), not only by whatever seed signed it.

import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: ed25519-verify <public-key> <signature> <file>\n".utf8))
    exit(2)
}
guard let keyData = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]),
      let file = FileManager.default.contents(atPath: args[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else {
    FileHandle.standardError.write(Data("error: unreadable key, signature or file\n".utf8))
    exit(1)
}
exit(key.isValidSignature(signature, for: file) ? 0 : 1)
