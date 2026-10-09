import XCTest
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import RoyalVNCKit

// Known-answer tests for the CryptoSwift-backed primitives used by the ARD / MSLogonII auth paths.
final class CryptoKATTests: XCTestCase {
    private func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    // FIPS-197 Appendix C.1 (AES-128)
    func testKAT_AES128ECB_FIPS197() {
        let key = hex("000102030405060708090a0b0c0d0e0f")
        let plaintext = hex("00112233445566778899aabbccddeeff")

        XCTAssertEqual(plaintext.aes128ECBEncrypted(withKey: key), hex("69c4e0d86a7b0430d8cdb78070b4c55a"))
        // Two identical blocks encrypt independently under ECB, no extra padding block
        XCTAssertEqual((plaintext + plaintext).aes128ECBEncrypted(withKey: key),
                       hex("69c4e0d86a7b0430d8cdb78070b4c55a69c4e0d86a7b0430d8cdb78070b4c55a"))
    }

    // RFC 1321 Appendix A.5
    func testKAT_MD5_RFC1321() {
        let vectors: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b")
        ]

        for (input, expected) in vectors {
            XCTAssertEqual(Data(input.utf8).md5Hash(), hex(expected), input)
        }
    }

    func testKAT_BigNumModExp() {
        // 4^13 mod 497 = 445, 2^10 mod 1000 = 24
        let cases: [(UInt8, UInt8, UInt16, UInt16)] = [
            (4, 13, 497, 445),
            (2, 10, 1000, 24)
        ]

        for (g, x, p, expected) in cases {
            let y = BigNum()
            XCTAssertTrue(BigNum.modExp(y: y,
                                        g: BigNum(data: Data([ g ]))!,
                                        x: BigNum(data: Data([ x ]))!,
                                        p: BigNum(data: Data([ UInt8(p >> 8), UInt8(p & 0xff) ]))!))
            XCTAssertEqual(y.bigEndianData(paddedTo: 2), Data([ UInt8(expected >> 8), UInt8(expected & 0xff) ]))
        }
    }
}
