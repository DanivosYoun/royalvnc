#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - CryptoSwift Implementation
@_implementationOnly import CryptoSwift

final class BigNum {
    private var bigInt: BigUInteger

    init() {
        self.bigInt = .init()
    }

    init?(data: Data) {
        self.bigInt = .init(data)
    }
}

extension BigNum {
    var isZero: Bool {
        let isIt = self.bigInt == 0
        
        return isIt
    }

    var bytesCount: Int32 {
        let count = self.bigInt.serialize().count
        
        return .init(count)
    }

    var bitsCount: Int32 {
        let count = self.bigInt.bitWidth

        return .init(count)
    }

    func rand(range: BigNum) -> Bool {
        self.bigInt = CS.BigUInt.randomInteger(lessThan: range.bigInt)
        
        return true
    }

    /// Random exponent of exactly `bits` bits.
    ///
    /// Diffie-Hellman does not need a private exponent as wide as the modulus, and
    /// CryptoSwift's `power(_:modulus:)` walks **every bit of every word** of the
    /// exponent with no early exit — so a full-width 4096-bit exponent costs 64
    /// words where 4 would do. Measured on the same 4096-bit modulus: full width
    /// 0.333s, 256-bit 0.019s (17.5x). gtk-vnc, the reference client for this exact
    /// Apple handshake, has used a 31-bit exponent for years; 256 bits is far more
    /// conservative than that while keeping the win.
    func rand(bits: Int) -> Bool {
        var value = CS.BigUInt.randomInteger(withExactWidth: bits)

        // Degenerate exponents would leak the shared secret outright.
        if value < 2 {
            value = 2
        }

        self.bigInt = value

        return true
    }

    static func modExp(y: BigNum,
                       g: BigNum,
                       x: BigNum,
                       p: BigNum) -> Bool {
        y.bigInt = g.bigInt.power(x.bigInt, modulus: p.bigInt)
        
        return true
    }

    func bigEndianData() -> Data? {
        let data = self.bigInt.serialize()
        
        return data
    }

    /// Big-endian bytes, left-padded with zeros to exactly `length`.
    ///
    /// `serialize()` returns the minimal encoding, so any value whose top byte is
    /// zero comes back short — about 1 in 256. Every peer of this handshake (gtk-vnc
    /// `vnc_mpi_to_bytes`, OpenSSL, noVNC) writes fixed key-size buffers, so a short
    /// encoding silently changes both what goes on the wire and what gets hashed.
    func bigEndianData(paddedTo length: Int) -> Data? {
        guard let data = bigEndianData() else { return nil }
        guard data.count <= length else { return nil }
        guard data.count < length else { return data }

        return Data(repeating: 0, count: length - data.count) + data
    }
}


// MARK: - libtommath Implementation
//@_implementationOnly import libtommath
//
//final class BigNum {
//	private let num: UnsafeMutablePointer<BIGNUM>
//	private let backingDataPointer: UnsafeMutablePointer<UInt8>?
//
//	init() {
//		self.num = BN_new()
//		self.backingDataPointer = nil
//	}
//
//	init?(data: Data) {
//		let dataLength = data.count
//
//		let backingDataPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: dataLength)
//		data.copyBytes(to: backingDataPtr, count: dataLength)
//
//		guard let num = BN_bin2bn(backingDataPtr, .init(dataLength), nil) else {
//			backingDataPtr.deallocate()
//
//			return nil
//		}
//
//		self.num = num
//		self.backingDataPointer = backingDataPtr
//	}
//
//	deinit {
//		backingDataPointer?.deallocate()
//
//		BN_free(num)
//	}
//}
//
//extension BigNum {
//	var isZero: Bool {
//		let isItNum = BN_is_zero(num)
//		let isIt = isItNum != 0
//
//		return isIt
//	}
//
//	var bytesCount: Int32 {
//		let count = BN_num_bytes(num)
//
//		return count
//	}
//
//	var bitsCount: Int32 {
//		let count = BN_num_bits(num)
//
//		return count
//	}
//
//	func rand(range: BigNum) -> Bool {
//		let successNum = BN_rand_range(num, range.num)
//		let success = successNum != 0
//
//		return success
//	}
//
//	static func modExp(y: BigNum,
//					   g: BigNum,
//					   x: BigNum,
//					   p: BigNum) -> Bool {
//		let successNum = BN_mod_exp(y.num,
//									g.num,
//									x.num,
//									p.num)
//
//		let success = successNum != 0
//
//		return success
//	}
//
//	func bigEndianData() -> Data? {
//		let expectedLength = bytesCount
//
//		var data = Data(count: .init(expectedLength))
//
//		let actualLength = data.withUnsafeMutableBytes { dataBufferPtr in
//			guard let dataPtr = dataBufferPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
//				return 0
//			}
//
//			let convertedLength = BN_bn2bin(num, dataPtr)
//
//			return .init(convertedLength)
//		}
//
//		guard actualLength == expectedLength else {
//			return nil
//		}
//
//		return data
//	}
//}
