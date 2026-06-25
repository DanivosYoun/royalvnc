#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct ClientCutText: VNCSendableMessage {
		let messageType: UInt8 = 6

		// UTF-8 (not RFB-legacy ISO Latin-1): Latin-1 cannot encode Hangul/CJK/emoji — data(using:)
		// returns nil → an EMPTY cut-text was sent. UTF-8 is the de-facto modern encoding (macOS Screen
		// Sharing speaks it) and is byte-identical to Latin-1 for ASCII. (CNDF clipboard fix.)
		static let stringEncoding: String.Encoding = .utf8

		let text: String
	}
}

extension VNCProtocol.ClientCutText {
	var data: Data {
		var latin1TextData = text.data(using: Self.stringEncoding) ?? .init()
		var textLength = latin1TextData.count
		
		if textLength > UInt32.max {
			textLength = .init(UInt32.max)
			latin1TextData = .init(latin1TextData.subdata(in: 0..<textLength))
		}
		
		let length = 8 + textLength
		
		var data = Data(capacity: length)

		data.append(messageType)
		data.appendPadding(length: 3)
		
		data.append(UInt32(textLength), bigEndian: true)
		data.append(contentsOf: latin1TextData)
		
		guard data.count == length else {
			fatalError("VNCProtocol.ClientCutText data.count (\(data.count)) != \(length)")
		}
		
		return data
	}
	
	func send(connection: NetworkConnectionWriting) async throws {
		try await connection.write(data: data)
	}
}
