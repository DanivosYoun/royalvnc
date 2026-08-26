#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Thread-safe FIFO with an async "wait until something arrives" signal.
///
/// Two problems lived in the previous plain-`struct` version.
///
/// **It was a data race by construction.** Producers are AppKit's main thread
/// (`VNCCAFramebufferView` pointer/key events → `VNCConnection.mouseMove` /
/// `keyDown`), the clipboard monitor's timer, and the connection's own handshake
/// code; the single consumer is the send task. Two threads mutating the same
/// `Array` reliably crashes with *"Can't remove first element from an empty
/// collection"*, and under TSan shows a Swift access race in enqueue/dequeue
/// followed by a segfault in `Array.append`.
///
/// **The consumer polled.** With no way to be woken, the send loop slept 10ms
/// whenever the queue was empty, so every keystroke and pointer event waited up
/// to a further 10ms before it was even written to the socket, and an idle
/// session woke the process ~70 times a second. `waitForElement()` replaces that
/// sleep: it returns immediately when work is already queued and otherwise parks
/// until `enqueue` or `wake` runs.
final class Queue<T>: @unchecked Sendable {
	private let lock = NSLock()
	private var list = [T]()
	private var waiters = [CheckedContinuation<Void, Never>]()
	/// Set when a wake arrives with nobody parked, so the next `waitForElement()`
	/// returns immediately instead of sleeping through a signal it just missed.
	private var pendingWake = false

	func enqueue(_ element: T) {
		lock.lock()
		list.append(element)
		let resumed = waiters
		waiters.removeAll()
		lock.unlock()

		for waiter in resumed {
			waiter.resume()
		}
	}

	func dequeue() -> T? {
		lock.lock()
		defer { lock.unlock() }

		guard !list.isEmpty else { return nil }

		return list.removeFirst()
	}

	func clear() {
		lock.lock()
		list.removeAll()
		lock.unlock()

		// Anything parked is waiting for work that is now never coming.
		wake()
	}

	func peek() -> T? {
		lock.lock()
		defer { lock.unlock() }

		return list.first
	}

	var isEmpty: Bool {
		lock.lock()
		defer { lock.unlock() }

		return list.isEmpty
	}

	/// Suspends until the queue is non-empty, the task is cancelled, or `wake()`
	/// is called. Returns immediately if an element is already queued.
	///
	/// The send loop is not driven by task cancellation — it exits on
	/// `disconnectRequested` — so `beginDisconnecting` must call `wake()`, or a
	/// parked send task would never observe the disconnect and would keep the
	/// connection alive forever.
	func waitForElement() async {
		await withTaskCancellationHandler {
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				lock.lock()

				if !list.isEmpty || pendingWake {
					pendingWake = false
					lock.unlock()
					continuation.resume()

					return
				}

				waiters.append(continuation)
				lock.unlock()
			}
		} onCancel: {
			wake()
		}
	}

	/// Resumes everything parked in `waitForElement()`.
	func wake() {
		lock.lock()
		let resumed = waiters
		waiters.removeAll()

		// A wake that finds nobody parked must not be lost: the waiter may be
		// between its emptiness check and appending itself.
		if resumed.isEmpty {
			pendingWake = true
		}

		lock.unlock()

		for waiter in resumed {
			waiter.resume()
		}
	}
}
