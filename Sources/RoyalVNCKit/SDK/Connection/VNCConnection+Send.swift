#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Client to Server Messages
extension VNCConnection {
	func startSendLoop() {
        logger.logDebug("Starting send loop")

		sendTask = Task(priority: taskPriority) {
			while !state.disconnectRequested,
                  connection.isReady {
				do {
					try await send()
				} catch {
					handleBreakingError(error)
				}
			}

			// However the loop ended, nothing executes input anymore: do not leave a close waiting for it.
			inputLedger.connectionDidClose()
		}
	}

	/// Ask for the next framebuffer update.
	///
	/// Normally a no-op while Continuous Updates is enabled — the server is supposed
	/// to be pushing. `bypassingContinuousUpdates` is for the safety poll in
	/// `enableContinuousUpdates()`, which exists precisely because a server can
	/// acknowledge the extension and then push nothing.
	func sendFramebufferUpdateRequest(bypassingContinuousUpdates: Bool = false) async throws {
		guard let framebuffer,
              bypassingContinuousUpdates || !state.areContinuousUpdatesEnabled else {
            return
        }
        
		let incremental = state.incrementalUpdatesEnabled

		let fullFramebufferRegion = VNCRegion(location: .zero,
											  size: framebuffer.size)

		// Request next update
		try await sendFramebufferUpdateRequest(incremental: incremental,
											   region: fullFramebufferRegion)

		if !incremental {
			state.incrementalUpdatesEnabled = true
		}
	}

	func sendEnableContinuousUpdates() async throws {
		guard let framebuffer,
              state.areContinuousUpdatesSupported,
              !state.areContinuousUpdatesEnabled else {
            return
        }

		let fullFramebufferRegion = VNCRegion(location: .zero,
											  size: framebuffer.size)

		try await sendEnableContinuousUpdates(enable: true,
											  region: fullFramebufferRegion)

		state.areContinuousUpdatesEnabled = true
	}
}

extension VNCConnection {
	/// One step of the send loop behind the readiness gate: the releases of closing input handles
	/// first, then the next queued item. Returns false when there was nothing to do.
	func sendNext() async throws -> Bool {
		let released = try await sendPendingInputReleases()

		guard let outbound = clientToServerMessageQueue.dequeue() else { return released }

		switch outbound {
			case .message(let message):
				try await sendMessage(message)
			case .input(let batch):
				try await sendInput(batch)
		}

		return true
	}
}

private extension VNCConnection {
	/// The last executor of input. A batch whose handle is closing is dropped here, and a batch
	/// that has started runs to its end before any release of its handle.
	func sendInput(_ batch: VNCInputBatch) async throws {
		guard inputLedger.begin(batch.owner) else { return }

		defer { inputLedger.end(batch.owner) }

		for action in batch.actions {
			for step in inputLedger.steps(for: action, owner: batch.owner) {
				// Nothing to write also covers a connection that went away while the batch ran.
				guard let send = inputLedger.resolve(step, owner: batch.owner) else { continue }

				try await sendMessage(send.message)

				inputLedger.commit(send)
			}
		}
	}

	func sendPendingInputReleases() async throws -> Bool {
		var didSend = false

		while let send = inputLedger.nextRelease() {
			do {
				try await sendMessage(send.message)
			} catch {
				inputLedger.releaseFailed(send.owner)

				throw error
			}

			inputLedger.commit(send)

			didSend = true
		}

		return didSend
	}

	func send() async throws {
		guard !state.disconnectRequested,
              connection.isReady else {
			// Not writable yet. There is nothing to be woken by, so back off.
			try await Task.sleep(seconds: 0.01)

			return
		}

		guard try await sendNext() else {
			// Park until something is enqueued rather than polling every 10ms.
			// The poll put up to 10ms in front of every key and pointer event —
			// the send loop is the only thing between an NSEvent and the socket —
			// and woke an idle session ~70 times a second for nothing.
			await clientToServerMessageQueue.waitForElement()

			return
		}
	}

	func sendFramebufferUpdateRequest(incremental: Bool,
									  region: VNCRegion) async throws {
		let framebufferUpdateRequest = VNCProtocol.FramebufferUpdateRequest(incremental: incremental,
																			xPosition: region.location.x,
																			yPosition: region.location.y,
																			width: region.size.width,
																			height: region.size.height)

		try await sendMessage(framebufferUpdateRequest)
	}

	func sendEnableContinuousUpdates(enable: Bool,
									 region: VNCRegion) async throws {
		let message = VNCProtocol.EnableContinuousUpdates(enable: enable,
														  xPosition: region.x,
														  yPosition: region.y,
														  width: region.width,
														  height: region.height)

		try await sendMessage(message)
	}

	func sendMessage(_ message: VNCSendableMessage) async throws {
		if let outboundWriter {
			try await message.send(connection: outboundWriter)
		} else {
			try await message.send(connection: connection)
		}
	}
}
