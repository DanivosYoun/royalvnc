#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Queue Management
extension VNCConnection {
	func enqueueKeyEvent(key: VNCKeyCode,
						 isDown: Bool,
						 identity: UInt32? = nil) {
		guard settings.inputMode != .none else { return }

		let isARD = state.isAppleRemoteDesktop
		let keyCode = key.rawValue(forAppleRemoteDesktop: isARD)

		let keyEvent = VNCProtocol.KeyEvent(isDown: isDown,
											key: keyCode)

		logger.logDebug("Enqueuing Key \(keyEvent.description)")

		// The local host's UP has always gone out unconditionally, even without a recorded DOWN.
		let action: VNCInputAction = isDown
			? .keyDown(identity: identity ?? key.rawValue, keysym: keyCode)
			: .keyUp(identity: identity ?? key.rawValue, fallbackKeysym: keyCode)

		enqueueInput(owner: inputLedger.local,
					 actions: [ action ])
	}

	func enqueueLocalPointerEvent(_ command: VNCSharedInputCommand) {
		guard settings.inputMode != .none else { return }

		enqueueInput(owner: inputLedger.local,
					 actions: inputActions(for: command))
	}

	/// The send loop decides at execution time, per owner, whether the batch still runs.
	func enqueueInput(owner: VNCInputOwner,
					  actions: [VNCInputAction]) {
		guard !actions.isEmpty else { return }

		clientToServerMessageQueue.enqueue(.input(VNCInputBatch(owner: owner,
																actions: actions)))
	}

	func keysym(for key: VNCKeyCode) -> UInt32 {
		key.rawValue(forAppleRemoteDesktop: state.isAppleRemoteDesktop)
	}

	func inputActions(for command: VNCSharedInputCommand) -> [VNCInputAction] {
		switch command {
			case .keyDown(let key, let identity):
				return [ .keyDown(identity: identity, keysym: keysym(for: key)) ]

			case .keyUp(let identity):
				return [ .keyUp(identity: identity, fallbackKeysym: nil) ]

			case .syncModifiers(let keys):
				return [ .syncModifiers(keys.map(keysym(for:))) ]

			case .keyChord(let keys):
				return [ .chord(keys.map(keysym(for:))) ]

			case .pointerMove(let x, let y):
				return [ .pointer(.none, normalizedMousePosition(x: x, y: y)) ]

			case .buttonDown(let button, let x, let y):
				return [ .pointer(.down(button.mousePointerButton), normalizedMousePosition(x: x, y: y)) ]

			case .buttonUp(let button, let x, let y):
				return [ .pointer(.up(button.mousePointerButton), normalizedMousePosition(x: x, y: y)) ]

			case .wheel(let wheel, let x, let y, let steps):
				let button = wheel.mousePointerButton
				let position = normalizedMousePosition(x: x, y: y)

				// Each step is a press and a release, executed back to back.
				return (0..<steps).flatMap({ _ in
					[ VNCInputAction.pointer(.down(button), position),
					  VNCInputAction.pointer(.up(button), position) ]
				})
		}
	}

	func enqueueClientCutTextMessage(_ text: String) {
		let clientCutTextMessage = VNCProtocol.ClientCutText(text: text)

		enqueueClientToServerMessage(clientCutTextMessage)
	}

	func enqueueClientToServerMessage(_ message: VNCSendableMessage) {
		clientToServerMessageQueue.enqueue(.message(message))
	}

    func normalizedMousePosition(x: UInt16,
                                 y: UInt16) -> VNCProtocol.MousePosition {
        var normalizedX = x
        var normalizedY = y

        let framebufferWidth = framebuffer?.size.width ?? 0
        let framebufferHeight = framebuffer?.size.height ?? 0

        if normalizedY > framebufferHeight {
            normalizedY = framebufferHeight
        }

        if normalizedX > framebufferWidth {
            normalizedX = framebufferWidth
        }

        let normalizedPosition = VNCProtocol.MousePosition(x: normalizedX,
                                                           y: normalizedY)

        return normalizedPosition
    }
}
