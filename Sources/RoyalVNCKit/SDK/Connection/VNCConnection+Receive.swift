#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Server to Client Messages
extension VNCConnection {
	func startReceiveLoop() {
        logger.logDebug("Starting receive loop")

        receiveTask = Task(priority: taskPriority) {
			while !state.disconnectRequested,
                  connection.isReady {
				do {
					try await receive()
				} catch {
					handleBreakingError(error)
				}
			}
		}
	}
}

private extension VNCConnection {
	func receive() async throws {
		guard !state.disconnectRequested else {
			// Just ignore, since disconnect has already been requested
			return
		}

        guard connection.isReady else {
			throw VNCError.connection(.notReady)
		}

		let serverToClientMessage = try await VNCProtocol.ServerToClientMessage.receive(connection: connection)

		try await didReceive(messageType: serverToClientMessage.messageType)
	}

	func didReceive(messageType: UInt8) async throws {
		switch messageType {
			case VNCProtocol.FramebufferUpdate.messageType:
				try await handleFramebufferUpdateMessage()

			case VNCProtocol.SetColourMapEntries.messageType:
				try await handleSetColourMapEntriesMessage()

			case VNCProtocol.ServerCutText.messageType:
				try await handleServerCutTextMessage()

			case VNCProtocol.Bell.messageType:
				try await handleBellMessage()

			case VNCProtocol.EndOfContinuousUpdates.messageType:
				try await handleEndOfContinuousUpdatesMessage()

			default:
				throw VNCError.protocol(.unsupportedServerToClientMessage(messageType: messageType))
		}
	}

	/// Switch Continuous Updates on, and keep a safety poll running behind it.
	///
	/// While it is on, `sendFramebufferUpdateRequest` is a no-op by design — that is
	/// the whole point — which also means a server that acknowledges the extension
	/// but never pushes leaves the screen frozen forever with nothing asking for
	/// pixels. An earlier revision of this fork shipped exactly that.
	///
	/// The obvious guard, "if no update arrives within N seconds, give up", does not
	/// work: **an idle desktop and a server that ignores the extension look
	/// identical from here.** Both produce silence. Deciding between them by
	/// counting updates gets it wrong in one direction or the other, and getting it
	/// wrong towards "the server is fine" is a frozen screen.
	///
	/// So do not decide. After a quiet stretch, just send one ordinary update
	/// request. Against a server that honours the extension this costs a 10-byte
	/// message on an idle connection and nothing else; against one that does not, it
	/// is the thing keeping the session alive. Correct either way, without needing to
	/// tell the two apart.
	func enableContinuousUpdates() async throws {
		try await sendEnableContinuousUpdates()

		guard state.areContinuousUpdatesEnabled else {
			// Nothing was sent (no framebuffer yet, or already on) — keep polling.
			try await sendFramebufferUpdateRequest()

			return
		}

		state.lastFramebufferUpdateAt = Date()

		logger.logDebug("Continuous Updates enabled; safety poll running")

		Task { [weak self] in
			while true {
				try? await Task.sleep(seconds: Self.continuousUpdatesPollSeconds)

				guard let self,
					  !self.state.disconnectRequested,
					  self.state.areContinuousUpdatesEnabled else {
					return
				}

				let quietFor = Date().timeIntervalSince(self.state.lastFramebufferUpdateAt)

				guard quietFor >= Self.continuousUpdatesPollSeconds else {
					continue
				}

				self.state.lastFramebufferUpdateAt = Date()

				// Deliberately bypassing the Continuous Updates guard: that guard is a
				// no-op exactly in the state we are insuring against.
				try? await self.sendFramebufferUpdateRequest(bypassingContinuousUpdates: true)
			}
		}
	}

	func handleFramebufferUpdateMessage() async throws {
		// Recorded before the framebuffer guard so the safety poll sees liveness even
		// in the (fatal) case where we have no framebuffer to draw into.
		state.lastFramebufferUpdateAt = Date()

		guard let framebuffer = framebuffer else {
			throw VNCError.protocol(.framebufferUpdateReceivedWithoutFramebuffer)
		}

		logger.logDebug("Receiving Framebuffer Update")

		let framebufferUpdate = try await VNCProtocol.FramebufferUpdate.receive(connection: connection,
																				framebuffer: framebuffer,
																				encodings: encodings,
																				logger: logger)

		logger.logDebug("Received Framebuffer Update: \(framebufferUpdate)")

		/*
		// Write out the framebuffer for testing purposes
		try framebuffer.writeSurface()
		*/

		try await sendFramebufferUpdateRequest()
	}

	func handleSetColourMapEntriesMessage() async throws {
		guard let framebuffer = framebuffer else {
			throw VNCError.protocol(.setColourMapEntriesReceivedWithoutFramebuffer)
		}

		logger.logDebug("Receiving Colour Map Entries")

		let colourMapEntries = try await VNCProtocol.SetColourMapEntries.receive(connection: connection,
																				 logger: logger)

		logger.logDebug("Received Colour Map Entries")

		framebuffer.updateColorMap(colourMapEntries)
	}

	func handleServerCutTextMessage() async throws {
		logger.logDebug("Receiving Clipboard Text from Server")

		let serverCutText = try await VNCProtocol.ServerCutText.receive(connection: connection,
																		logger: logger)

		let text = serverCutText.text

		logger.logDebug("Received Clipboard Text from Server")

		guard settings.isClipboardRedirectionEnabled else { return }

		clipboard.text = text
	}

	func handleBellMessage() async throws {
		logger.logDebug("Receiving Bell Message from Server")

		_ = try await VNCProtocol.Bell.receive(connection: connection,
											   logger: logger)

		logger.logDebug("Received Bell Message from Server")

		systemSound.play()
	}

	func handleEndOfContinuousUpdatesMessage() async throws {
		let first = !state.areContinuousUpdatesSupported

		state.areContinuousUpdatesSupported = true
		state.areContinuousUpdatesEnabled = false

		if first {
			logger.logDebug("Continuous Updates supported (server sent EndOfContinuousUpdates)")
		} else {
			logger.logDebug("Disabling Continuous Updates")
		}

		// Actually turn the extension on. Advertising -313 and then never sending
		// EnableContinuousUpdates left every frame costing a full round trip: the
		// client asks, waits, decodes, asks again. Measured against a mock server at
		// 25ms one-way that ping-pong caps out at ~15fps, while the same server with
		// no delay reaches ~7000 — the entire difference is the round trip.
		//
		// Only on the *first* EndOfContinuousUpdates: later ones are the server
		// acknowledging that it stopped, and re-enabling there would loop.
		if first {
			try await enableContinuousUpdates()

			return
		}

		try await sendFramebufferUpdateRequest()
	}
}
