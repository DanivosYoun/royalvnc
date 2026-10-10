#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Public API

/// One input action of a shared (remote-controlled) session. Translated by the owner of the handle,
/// executed by the connection's send loop. A UP names the identity of the DOWN it ends; the keysym that
/// is released is the one the DOWN actually sent.
public enum VNCSharedInputCommand: Equatable {
	case keyDown(VNCKeyCode, identity: UInt32)
	case keyUp(identity: UInt32)

	/// Level-triggered: after it ran, the modifiers this handle holds are exactly these. The send loop
	/// diffs against what it really sent, releases the ones that are gone in reverse press order and
	/// presses the new ones in the order given. A modifier somebody else holds is claimed, not re-sent.
	case syncModifiers([VNCKeyCode])

	/// Presses every key in order and releases them in reverse, as one execution unit. A key that is
	/// already down (held by this handle, by the local host or by another handle) is neither pressed nor
	/// released, so the chord never takes away what was held before it.
	case keyChord([VNCKeyCode])

	case pointerMove(x: UInt16, y: UInt16)
	case buttonDown(VNCMouseButton, x: UInt16, y: UInt16)
	case buttonUp(VNCMouseButton, x: UInt16, y: UInt16)
	case wheel(VNCMouseWheel, x: UInt16, y: UInt16, steps: UInt32)
}

public enum VNCSharedInputCloseFailure: Equatable {
	/// The connection went away before every release was written.
	case connectionLost

	/// A release write failed.
	case sendFailed
}

public enum VNCSharedInputCloseResult: Equatable {
	/// Everything the share had put down was released and each release write completed.
	/// There is no acknowledgement from the remote side; this is as far as the client can know.
	case released

	/// The share's input was cancelled, but its release is not proven.
	case failed(VNCSharedInputCloseFailure)
}

public enum VNCSharedInputError: Error, Equatable {
	/// A previous share on this connection could not be released. Reconnect before sharing input again.
	case connectionPoisoned

	case connectionClosed
}

public extension VNCConnection {
	/// Creates the input handle for one share. The handle is bound to this connection, starts out
	/// prepared (it accepts nothing), and is never rebound to another connection or share.
	func makeSharedInputSession() throws -> VNCSharedInputSession {
		let owner = try inputLedger.makeOwner()

		return VNCSharedInputSession(connection: self,
									 owner: owner)
	}
}

/// `prepared → active → closing → closed`, one way only.
///
/// `submit` is an admission, not a delivery: the send loop decides at execution time whether the
/// handle still lives, and it alone records what was really written.
public final class VNCSharedInputSession: @unchecked Sendable {
	private let connection: VNCConnection
	private let owner: VNCInputOwner

	init(connection: VNCConnection,
		 owner: VNCInputOwner) {
		self.connection = connection
		self.owner = owner
	}

	deinit {
		beginClose()
	}

	/// Starts accepting input. Returns false, permanently, once the handle is closing or closed,
	/// or when the connection can no longer carry RW shares.
	public func activate() -> Bool {
		connection.inputLedger.activate(owner)
	}

	/// Accepts the commands as one execution unit: the send loop runs them back to back and never
	/// interleaves this handle's release with them. Returns false if the handle does not accept input.
	public func submit(_ commands: [VNCSharedInputCommand]) -> Bool {
		guard connection.settings.inputMode != .none,
			  connection.inputLedger.isAccepting(owner) else {
			return false
		}

		connection.enqueueInput(owner: owner,
								actions: commands.flatMap(connection.inputActions))

		return true
	}

	public func submit(_ command: VNCSharedInputCommand) -> Bool {
		submit([ command ])
	}

	/// Synchronously forbids new input. Commands that were accepted but not executed yet are
	/// discarded by the send loop. Idempotent.
	public func beginClose() {
		if connection.inputLedger.beginClose(owner) {
			connection.clientToServerMessageQueue.wake()
		}
	}

	/// Waits for the send loop to finish the release. Cancelling the calling task does not cancel
	/// the teardown, which belongs to the send loop. Every call returns the same result.
	public func finishClose() async -> VNCSharedInputCloseResult {
		beginClose()

		return await connection.inputLedger.awaitClose(owner)
	}
}

// MARK: - Executor-side model

/// Something the send loop executes in order. Input keeps its owner all the way to the socket.
enum VNCOutbound {
	case message(VNCSendableMessage)
	case input(VNCInputBatch)
}

struct VNCInputBatch {
	let owner: VNCInputOwner
	let actions: [VNCInputAction]
}

enum VNCPointerChange {
	case none
	case down(VNCProtocol.MousePointerButton)
	case up(VNCProtocol.MousePointerButton)
}

/// What a command means. Expanded into steps by the send loop, against what was really sent.
enum VNCInputAction {
	case keyDown(identity: UInt32, keysym: UInt32)

	/// `fallbackKeysym` is only set for the local owner, whose UP has always been sent without a recorded DOWN.
	case keyUp(identity: UInt32, fallbackKeysym: UInt32?)

	case syncModifiers([UInt32])
	case chord([UInt32])
	case pointer(VNCPointerChange, VNCProtocol.MousePosition)
}

/// One write (or one claim that needs none), resolved right before it is sent.
enum VNCInputStep {
	/// `isForced` writes the DOWN even if the key is down already (a repeat). Otherwise a key that
	/// somebody holds is only claimed.
	case press(VNCHeldKey.Source, keysym: UInt32, isForced: Bool)
	case release(VNCHeldKey.Source, keysym: UInt32)
	case releaseUnowned(keysym: UInt32)
	case pointer(VNCPointerChange, VNCProtocol.MousePosition)
}

/// A key an owner put down. Two identities of one keysym are two claims; one identity of one keysym is one.
struct VNCHeldKey: Equatable {
	enum Source: Equatable {
		case identity(UInt32)
		case modifier
		case chord
	}

	let source: Source
	let keysym: UInt32
}

/// Who put what down. All mutable state is guarded by `VNCInputLedger.lock`.
final class VNCInputOwner {
	enum Phase {
		case prepared
		case active
		case closing
		case closed(VNCSharedInputCloseResult)
	}

	let isLocal: Bool

	var phase: Phase
	var keys: [VNCHeldKey] = []
	var buttons: VNCProtocol.MousePointerButton = [ ]
	var isExecuting = false
	var waiters: [CheckedContinuation<VNCSharedInputCloseResult, Never>] = []

	init(isLocal: Bool) {
		self.isLocal = isLocal
		self.phase = isLocal ? .active : .prepared
	}

	var isActive: Bool {
		if case .active = phase { return true }
		return false
	}

	var isClosing: Bool {
		if case .closing = phase { return true }
		return false
	}

	var holdsInput: Bool {
		!keys.isEmpty || !buttons.isEmpty
	}
}

/// One wire message plus what to record once its write completed.
struct VNCInputSend {
	enum Commit {
		case none
		case key(VNCHeldKey)
		case button(VNCProtocol.MousePointerButton)
		case allButtons
	}

	let owner: VNCInputOwner
	let message: VNCSendableMessage
	let commit: Commit
}

/// The record of what was really written to the server. Mutated only on behalf of the send loop
/// (`steps`/`resolve`/`commit`/`nextRelease`); other threads only admit, close and wait.
final class VNCInputLedger: @unchecked Sendable {
	private let lock = NSLock()

	let local = VNCInputOwner(isLocal: true)

	private var owners: [VNCInputOwner] = []
	private var lastPointer = VNCProtocol.MousePosition(x: 0, y: 0)
	private var isPoisoned = false
	private var isDisconnected = false

	private static let modifierKeysyms = Set([
		VNCKeyCode.shift, .rightShift,
		.control, .rightControl,
		.option, .optionForARD, .rightOption, .rightOptionForARD,
		.command, .commandForARD, .rightCommand, .rightCommandForARD
	].map({ $0.rawValue }))

	// MARK: Handle lifecycle (any thread)

	func makeOwner() throws -> VNCInputOwner {
		lock.lock()
		defer { lock.unlock() }

		guard !isPoisoned else { throw VNCSharedInputError.connectionPoisoned }
		guard !isDisconnected else { throw VNCSharedInputError.connectionClosed }

		let owner = VNCInputOwner(isLocal: false)

		owners.append(owner)

		return owner
	}

	func activate(_ owner: VNCInputOwner) -> Bool {
		lock.lock()
		defer { lock.unlock() }

		guard !isPoisoned, !isDisconnected else { return false }

		switch owner.phase {
			case .prepared:
				owner.phase = .active
				return true
			case .active:
				return true
			case .closing, .closed:
				return false
		}
	}

	func isAccepting(_ owner: VNCInputOwner) -> Bool {
		lock.lock()
		defer { lock.unlock() }

		return owner.isActive && !isDisconnected
	}

	/// Returns true if the send loop has work to do for this owner.
	func beginClose(_ owner: VNCInputOwner) -> Bool {
		lock.lock()

		switch owner.phase {
			case .prepared, .active:
				owner.phase = .closing
			case .closing, .closed:
				break
		}

		var resumes: [() -> Void] = []

		if owner.isClosing {
			resumes = settle(owner)
		}

		let needsLoop = owner.isClosing

		lock.unlock()

		resumes.forEach { $0() }

		return needsLoop
	}

	func awaitClose(_ owner: VNCInputOwner) async -> VNCSharedInputCloseResult {
		await withCheckedContinuation { (continuation: CheckedContinuation<VNCSharedInputCloseResult, Never>) in
			lock.lock()

			if case .closed(let result) = owner.phase {
				lock.unlock()
				continuation.resume(returning: result)

				return
			}

			owner.waiters.append(continuation)
			lock.unlock()
		}
	}

	/// The send loop is over, because the connection is going away or because it stopped on its own.
	/// Nothing will be written anymore: closing handles complete once their running batch has ended.
	func connectionDidClose() {
		lock.lock()

		isDisconnected = true

		var resumes: [() -> Void] = []

		for owner in owners where owner.isClosing {
			resumes += settle(owner)
		}

		lock.unlock()

		resumes.forEach { $0() }
	}

	// MARK: Execution (send loop)

	/// Last executor's gate: false means the batch belongs to a handle that no longer lives.
	func begin(_ owner: VNCInputOwner) -> Bool {
		lock.lock()
		defer { lock.unlock() }

		guard !isDisconnected, owner.isActive else { return false }

		owner.isExecuting = true

		return true
	}

	func end(_ owner: VNCInputOwner) {
		lock.lock()

		owner.isExecuting = false

		let resumes = owner.isClosing ? settle(owner) : []

		lock.unlock()

		resumes.forEach { $0() }
	}

	/// Expands an action against what was really sent so far. Nothing is recorded here; the unit runs
	/// to its end, so the snapshot is exact for every step of it.
	func steps(for action: VNCInputAction,
			   owner: VNCInputOwner) -> [VNCInputStep] {
		lock.lock()
		defer { lock.unlock() }

		guard !isDisconnected else { return [ ] }

		switch action {
			case .keyDown(let identity, let keysym):
				return [ .press(.identity(identity), keysym: keysym, isForced: true) ]

			case .keyUp(let identity, let fallbackKeysym):
				let held = owner.keys.filter({ $0.source == .identity(identity) })

				guard !held.isEmpty else {
					return fallbackKeysym.map({ [ .releaseUnowned(keysym: $0) ] }) ?? [ ]
				}

				return held.reversed().map({ .release($0.source, keysym: $0.keysym) })

			case .syncModifiers(let desired):
				let wanted = Self.unique(desired)
				let current = owner.keys.filter({ $0.source == .modifier }).map({ $0.keysym })

				let releases = current.reversed().filter({ !wanted.contains($0) })
				let presses = wanted.filter({ !current.contains($0) })

				return releases.map({ .release(.modifier, keysym: $0) })
					+ presses.map({ .press(.modifier, keysym: $0, isForced: false) })

			case .chord(let keysyms):
				let pressed = Self.unique(keysyms).filter({ holders(of: $0) == 0 })

				return pressed.map({ .press(.chord, keysym: $0, isForced: true) })
					+ pressed.reversed().map({ .release(.chord, keysym: $0) })

			case .pointer(let change, let position):
				return [ .pointer(change, position) ]
		}
	}

	/// Turns one step into the write it needs, if any, and records what is put down before the write,
	/// so a failed DOWN stays the share's responsibility. A UP is only recorded after its write.
	func resolve(_ step: VNCInputStep,
				 owner: VNCInputOwner) -> VNCInputSend? {
		lock.lock()
		defer { lock.unlock() }

		guard !isDisconnected else { return nil }

		switch step {
			case .press(let source, let keysym, let isForced):
				let key = VNCHeldKey(source: source, keysym: keysym)
				let isDown = holders(of: keysym) > 0

				if !owner.keys.contains(key) {
					owner.keys.append(key)
				}

				guard isForced || !isDown else { return nil }

				let keyEvent = VNCProtocol.KeyEvent(isDown: true, key: keysym)

				return .init(owner: owner, message: keyEvent, commit: .none)

			case .release(let source, let keysym):
				let key = VNCHeldKey(source: source, keysym: keysym)

				guard owner.keys.contains(key) else { return nil }

				return release(key, of: owner)

			case .releaseUnowned(let keysym):
				// Somebody holding the key keeps it down, even for an UP nobody recorded a DOWN for.
				guard holders(of: keysym) == 0 else { return nil }

				let keyEvent = VNCProtocol.KeyEvent(isDown: false, key: keysym)

				return .init(owner: owner, message: keyEvent, commit: .none)

			case .pointer(let change, let position):
				var mask = buttons(excluding: owner)

				switch change {
					case .none:
						mask.formUnion(owner.buttons)
					case .down(let button):
						owner.buttons.insert(button)
						mask.formUnion(owner.buttons)
					case .up(let button):
						mask.formUnion(owner.buttons.subtracting(button))
				}

				lastPointer = position

				let commit: VNCInputSend.Commit

				if case .up(let button) = change {
					commit = .button(button)
				} else {
					commit = .none
				}

				let pointerEvent = VNCProtocol.PointerEvent(buttons: mask, position: position)

				return .init(owner: owner, message: pointerEvent, commit: commit)
		}
	}

	func commit(_ send: VNCInputSend) {
		lock.lock()
		defer { lock.unlock() }

		switch send.commit {
			case .none:
				break
			case .key(let key):
				if let index = send.owner.keys.firstIndex(of: key) {
					send.owner.keys.remove(at: index)
				}
			case .button(let button):
				send.owner.buttons.remove(button)
			case .allButtons:
				send.owner.buttons = [ ]
		}
	}

	/// The next write that releases what a closing handle still holds: buttons at the last pointer
	/// position, then keys, modifiers last, each in reverse press order. Owners with nothing left
	/// are completed here.
	func nextRelease() -> VNCInputSend? {
		lock.lock()

		var next: VNCInputSend?
		var resumes: [() -> Void] = []

		for owner in owners where owner.isClosing && !owner.isExecuting && !isDisconnected {
			if let send = releaseStep(for: owner) {
				next = send
				break
			}

			resumes += complete(owner, with: .released)
		}

		lock.unlock()

		resumes.forEach { $0() }

		return next
	}

	func releaseFailed(_ owner: VNCInputOwner) {
		lock.lock()

		let resumes = complete(owner, with: .failed(.sendFailed))

		lock.unlock()

		resumes.forEach { $0() }
	}

	// MARK: Locked helpers

	private static func unique(_ keysyms: [UInt32]) -> [UInt32] {
		var seen = Set<UInt32>()

		return keysyms.filter({ seen.insert($0).inserted })
	}

	private func buttons(excluding owner: VNCInputOwner) -> VNCProtocol.MousePointerButton {
		var mask: VNCProtocol.MousePointerButton = [ ]

		for other in [ local ] + owners where other !== owner {
			mask.formUnion(other.buttons)
		}

		return mask
	}

	/// How many claims, of any owner, hold this keysym down.
	private func holders(of keysym: UInt32) -> Int {
		([ local ] + owners).reduce(0) { count, owner in
			count + owner.keys.filter({ $0.keysym == keysym }).count
		}
	}

	/// A key somebody else still holds stays down: only this claim is dropped.
	private func release(_ key: VNCHeldKey,
						 of owner: VNCInputOwner) -> VNCInputSend? {
		guard holders(of: key.keysym) <= 1 else {
			if let index = owner.keys.firstIndex(of: key) {
				owner.keys.remove(at: index)
			}

			return nil
		}

		let keyEvent = VNCProtocol.KeyEvent(isDown: false, key: key.keysym)

		return .init(owner: owner, message: keyEvent, commit: .key(key))
	}

	private func releaseStep(for owner: VNCInputOwner) -> VNCInputSend? {
		if !owner.buttons.isEmpty {
			let pointerEvent = VNCProtocol.PointerEvent(buttons: buttons(excluding: owner),
														position: lastPointer)

			return .init(owner: owner, message: pointerEvent, commit: .allButtons)
		}

		let pressed = owner.keys.reversed()
		let ordered = pressed.filter({ !Self.modifierKeysyms.contains($0.keysym) })
			+ pressed.filter({ Self.modifierKeysyms.contains($0.keysym) })

		for key in ordered {
			if let send = release(key, of: owner) {
				return send
			}
		}

		return nil
	}

	/// Completes a closing owner if nothing is left to wait for. Locked.
	private func settle(_ owner: VNCInputOwner) -> [() -> Void] {
		// A batch that is mid-write decides what is held; its outcome is not known before it ends.
		guard !owner.isExecuting else { return [ ] }

		if isDisconnected {
			let result: VNCSharedInputCloseResult = owner.holdsInput ? .failed(.connectionLost) : .released

			return complete(owner, with: result)
		}

		guard !owner.holdsInput else { return [ ] }

		return complete(owner, with: .released)
	}

	private func complete(_ owner: VNCInputOwner,
						  with result: VNCSharedInputCloseResult) -> [() -> Void] {
		guard case .closing = owner.phase else { return [ ] }

		owner.phase = .closed(result)
		owners.removeAll(where: { $0 === owner })

		if case .failed = result {
			isPoisoned = true
		}

		let waiters = owner.waiters
		owner.waiters.removeAll()

		return waiters.map({ waiter in { waiter.resume(returning: result) } })
	}
}
