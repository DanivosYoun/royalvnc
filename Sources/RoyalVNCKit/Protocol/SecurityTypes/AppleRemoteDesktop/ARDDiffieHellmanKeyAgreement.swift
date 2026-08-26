#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol.ARDAuthentication {
	struct DiffieHellmanKeyAgreement {
		let publicKey: Data
		let privateKey: Data
		let secretKey: Data

		init?(prime: Data,
			  generator: Data,
			  peerKey: Data,
			  keyLength: Int) {
			guard keyLength > 0 else {
				return nil
			}

			guard let keyPair = Self.generateKeyPair(generator: generator,
													 prime: prime,
													 keyLength: keyLength),
				  !keyPair.privateKey.isEmpty,
				  !keyPair.publicKey.isEmpty else {
				return nil
			}

			guard let secretKey = Self.computeSharedKey(prime: prime,
														peerKey: peerKey,
														privateKey: keyPair.privateKey),
				  !secretKey.isEmpty else {
				return nil
			}

			self.publicKey = keyPair.publicKey
			self.privateKey = keyPair.privateKey
			self.secretKey = secretKey
		}
	}
}

private extension VNCProtocol.ARDAuthentication.DiffieHellmanKeyAgreement {
	struct KeyPair {
		let publicKey: Data
		let privateKey: Data
	}

	/// Width of the DH private exponent. See `BigNum.rand(bits:)`.
	static let privateExponentBits = 256

	static func generateKeyPair(generator: Data,
								prime: Data,
								keyLength: Int) -> KeyPair? {
		let bigPrivKey = BigNum()
		let bigPubKey = BigNum()

		guard let bigPrime = BigNum(data: prime),
			  let bigGenerator = BigNum(data: generator) else {
			return nil
		}

		// Generate DH private key.
		//
		// A short exponent, not one as wide as the modulus: CryptoSwift's modular
		// exponentiation has no early exit, so exponent width is paid in full.
		// Capped by the modulus for tiny primes that a test server might send.
		let exponentBits = min(Self.privateExponentBits, max(2, Int(bigPrime.bitsCount) - 1))

		repeat {
			let randSuccess = bigPrivKey.rand(bits: exponentBits)

			guard randSuccess else {
				return nil
			}
		} while bigPrivKey.isZero

		let modSuccess = BigNum.modExp(y: bigPubKey,
									   g: bigGenerator,
									   x: bigPrivKey,
									   p: bigPrime)

		guard modSuccess else {
			return nil
		}

		// Left-pad to the server's key size rather than demanding that the minimal
		// encoding already happens to be exactly that wide.
		//
		// The old guard required `bytesCount == keyLength`, which `serialize()` fails
		// to satisfy whenever the value's top byte is zero — measured at ~0.7% of key
		// pairs, each one aborting the connection outright with no retry. Padding is
		// also what the wire format actually says: peers write fixed key-size buffers.
		//
		// The private key is padded too because `computeSharedKey` re-parses it, and
		// leading zeros are insignificant there.
		guard let privKey = bigPrivKey.bigEndianData(paddedTo: keyLength),
			  let pubKey = bigPubKey.bigEndianData(paddedTo: keyLength) else {
			return nil
		}

		let keyPair = KeyPair(publicKey: pubKey,
							  privateKey: privKey)

		return keyPair
	}

	static func computeSharedKey(prime: Data,
								 peerKey: Data,
								 privateKey: Data) -> Data? {
		guard let bigPrime = BigNum(data: prime),
			  let bigPrivKey = BigNum(data: privateKey),
			  let bigPeerKey = BigNum(data: peerKey) else {
			return nil
		}

		let bigSharedKey = BigNum()

		let modSuccess = BigNum.modExp(y: bigSharedKey,
									   g: bigPeerKey,
									   x: bigPrivKey,
									   p: bigPrime)

		guard modSuccess else {
			return nil
		}

		// Pad to the key size before it is handed to MD5. Unpadded, a shared secret
		// whose top byte is zero (~1 in 256) hashes to a different AES key than the
		// server's, and authentication is rejected for no visible reason. gtk-vnc's
		// `vnc_mpi_to_bytes` pads to keylen for exactly this reason.
		guard let sharedKey = bigSharedKey.bigEndianData(paddedTo: prime.count) else {
			return nil
		}

		return sharedKey
	}
}
