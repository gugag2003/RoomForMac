// Prints a fresh Ed25519 key pair for tests and the update rehearsal, never for a
// release: "<seed-base64> <public-key-base64>" on one line.
//
//   swift scripts/lib/ed25519-keypair.swift
//
// The seed is the 32-byte private key that Sparkle's `generate_appcast` and
// `sign_update` read with `--ed-key-file` (the format `generate_keys -x` writes),
// and the public key is the 32-byte value that goes into `SUPublicEDKey`.
// Nothing here touches the keychain or the network, so a test can make as many
// pairs as it likes. The real key comes from scripts/make-update-keys.sh.

import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
let seed = key.rawRepresentation.base64EncodedString()
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
print("\(seed) \(publicKey)")
