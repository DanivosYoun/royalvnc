import XCTest
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import RoyalVNCKit

// MARK: - Wire

/// What the fixture's writer observed once a write completed.
enum Wire: Equatable {
    case key(UInt32, down: Bool)
    case pointer(mask: UInt8, x: UInt16, y: UInt16)
    case other(UInt8)

    init(_ data: Data) {
        let bytes = [UInt8](data)

        switch bytes.first {
            case 4 where bytes.count == 8:
                let key = bytes[4...7].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                self = .key(key, down: bytes[1] != 0)
            case 5 where bytes.count == 6:
                self = .pointer(mask: bytes[1],
                                x: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                                y: UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
            default:
                self = .other(bytes.first ?? 0)
        }
    }

    var pointerMask: UInt8? {
        guard case .pointer(let mask, _, _) = self else { return nil }
        return mask
    }

    func isPointer(mask: UInt8) -> Bool {
        pointerMask == mask
    }
}

enum Outcome: Equatable {
    case released
    case failed
}

enum Op {
    case keyDown(UInt32, UInt32)
    case keyUp(UInt32)
    case move(UInt16, UInt16)
    case buttonDown(VNCMouseButton, UInt16, UInt16)
    case buttonUp(VNCMouseButton, UInt16, UInt16)
    case wheel(VNCMouseWheel, UInt16, UInt16, UInt32)
    case syncModifiers([UInt32])
    case chord([UInt32])
}

// MARK: - Controlled send fixture

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? { lock.withLock { stored } }
    func set(_ newValue: T) { lock.withLock { stored = newValue } }
}

/// A `NetworkConnectionWriting` whose completion the test controls: it can hold a write open, resume it, or fail it.
final class ControlledWriter: NetworkConnectionWriting, @unchecked Sendable {
    struct Injected: Error {}

    private let lock = NSLock()
    private var recorded: [Wire] = []
    private var holdNext = false
    private var failNext = false
    private var gate: CheckedContinuation<Void, Never>?
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    var events: [Wire] { lock.withLock { recorded } }

    func holdNextWrite() { lock.withLock { holdNext = true } }
    func failNextWrite() { lock.withLock { failNext = true } }

    func resume() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = gate
            gate = nil
            return continuation
        }

        continuation?.resume()
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let arrived = lock.withLock { () -> Bool in
                if gate != nil { return true }
                arrivalWaiters.append(continuation)
                return false
            }

            if arrived { continuation.resume() }
        }
    }

    func write(data: Data) async throws {
        let (fail, hold) = lock.withLock { () -> (Bool, Bool) in
            let state = (failNext, holdNext && !failNext)
            failNext = false
            if state.1 { holdNext = false }
            return state
        }

        if fail { throw Injected() }

        if hold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    gate = continuation
                    let waiters = arrivalWaiters
                    arrivalWaiters = []
                    return waiters
                }

                waiters.forEach { $0.resume() }
            }
        }

        lock.withLock { recorded.append(Wire(data)) }
    }
}
// MARK: - Tests

// The contract under test (design full-d-rdpinput.md, U2): the send loop is the last executor.
// It owns the sent state, discards the not-yet-executed input of a closing share, releases only what the
// share actually sent, and reports completion only after the release writes completed.
final class VNCSharedInputSessionTests: XCTestCase {
    private let a: UInt32 = 0x61
    private let b: UInt32 = 0x62
    private let shift: UInt32 = 0xffe1
    private let ctrl = VNCKeyCode.control.rawValue
    private let alt = VNCKeyCode.option.rawValue

    func testBacklogIsDiscardedAtLastExecutor() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()

        // Accepted and sitting in the native FIFO, never executed.
        XCTAssertTrue(share.submit([.keyDown(2, b), .buttonDown(.left, 30, 40)]))
        f.flushMainHop()

        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire, [.key(a, down: true), .key(a, down: false)])

        let boundary = f.wire.count
        await f.drain()
        XCTAssertEqual(f.wire.count, boundary, "nothing may be sent after the close completed")
    }

    func testUpRacingTeardownStillReleasesTheDown() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()

        // The UP is accepted but has not reached the executor when teardown begins.
        XCTAssertTrue(share.submit([.keyUp(1)]))
        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire, [.key(a, down: true), .key(a, down: false)],
                       "exactly one UP for the DOWN that was really sent")
    }

    func testCloseCompletionWaitsForTheReleaseSend() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()

        f.writer.holdNextWrite()
        share.beginClose()

        let observed = Box<Outcome>()
        let closing = Task { () -> Outcome in
            let result = await share.finishClose()
            observed.set(result)
            return result
        }
        let stepping = Task { await f.drain() }

        await f.writer.waitUntilBlocked()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNil(observed.value, "close reported complete while the release write was still pending")
        XCTAssertEqual(f.wire, [.key(a, down: true)])

        f.writer.resume()
        let result = await closing.value
        await stepping.value

        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire, [.key(a, down: true), .key(a, down: false)])
    }

    func testLocalOwnershipSurvivesShareClose() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        f.conn.keyDown(VNCKeyCode(a))
        f.conn.mouseButtonDown(.left, x: 5, y: 5)
        XCTAssertTrue(share.submit([.keyDown(1, a), .buttonDown(.left, 6, 6)]))
        await f.drain()

        share.beginClose()
        await f.drain()
        let result = await share.finishClose()
        XCTAssertEqual(result, .released)

        XCTAssertFalse(f.wire.contains(.key(a, down: false)),
                       "the share released a key the local host still holds")
        XCTAssertFalse(f.wire.contains(where: { $0.isPointer(mask: 0) }),
                       "the share released a button the local host still holds")
        XCTAssertEqual(f.wire.last?.pointerMask, 1)

        // Local release still works afterwards.
        f.conn.keyUp(VNCKeyCode(a))
        f.conn.mouseButtonUp(.left, x: 5, y: 5)
        await f.drain()
        XCTAssertEqual(Array(f.wire.suffix(2)), [.key(a, down: false), .pointer(mask: 0, x: 5, y: 5)])
    }

    func testReleaseUsesTheKeysymsThatWereSentAsDown() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        // Same physical key, different keysym on the repeat (shift released while it was held).
        XCTAssertTrue(share.submit([.keyDown(7, 0x41)]))
        _ = await f.step()
        XCTAssertTrue(share.submit([.keyDown(7, a)]))
        _ = await f.step()

        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire, [.key(0x41, down: true), .key(a, down: true),
                                .key(a, down: false), .key(0x41, down: false)])
    }

    func testRepeatedDownKeepsOneReleaseResponsibility() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        for _ in 0..<3 {
            XCTAssertTrue(share.submit([.keyDown(1, a)]))
            _ = await f.step()
        }

        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire, [.key(a, down: true), .key(a, down: true), .key(a, down: true),
                                .key(a, down: false)])
    }

    func testChordIsOneExecutionUnitAcrossClose() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.keyDown(1, shift), .keyDown(2, a)]))
        f.writer.holdNextWrite()
        f.flushMainHop()
        // The first write of the unit is in flight when teardown is requested.
        let stepping = Task { await f.drain() }
        await f.writer.waitUntilBlocked()
        share.beginClose()
        f.writer.resume()
        await stepping.value
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        // The unit finishes before teardown starts, and teardown releases in reverse press order.
        XCTAssertEqual(f.wire, [.key(shift, down: true), .key(a, down: true),
                                .key(a, down: false), .key(shift, down: false)])
    }

    func testWheelStepsAreDownUpPairs() async {
        let f = Fixture()
        f.conn.mouseWheel(.up, x: 7, y: 8, steps: 2)
        await f.drain()

        XCTAssertEqual(f.wire, [.pointer(mask: 8, x: 7, y: 8), .pointer(mask: 0, x: 7, y: 8),
                                .pointer(mask: 8, x: 7, y: 8), .pointer(mask: 0, x: 7, y: 8)])
    }

    func testWheelIsOneExecutionUnitAcrossClose() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.wheel(.up, 7, 8, 2)]))
        f.flushMainHop()
        f.writer.holdNextWrite()
        let stepping = Task { await f.drain() }
        await f.writer.waitUntilBlocked()
        share.beginClose()
        f.writer.resume()
        await stepping.value
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire, [.pointer(mask: 8, x: 7, y: 8), .pointer(mask: 0, x: 7, y: 8),
                                .pointer(mask: 8, x: 7, y: 8), .pointer(mask: 0, x: 7, y: 8)])
    }

    func testReleaseUsesTheLastExecutedPointerPosition() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.buttonDown(.left, 10, 20)]))
        _ = await f.step()
        XCTAssertTrue(share.submit([.move(30, 40)]))   // discarded, must not become the release position
        f.flushMainHop()

        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire, [.pointer(mask: 1, x: 10, y: 20), .pointer(mask: 0, x: 10, y: 20)])
    }

    func testFailedDownKeepsReleaseResponsibilityAndIsNotReportedAsSuccess() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        f.writer.failNextWrite()
        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()

        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .failed)
        XCTAssertFalse(f.canMakeShare(), "a release that could not be proven blocks RW handles on this connection")
    }

    func testReleaseWriteFailureIsNotSuccessAndBlocksFurtherHandles() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()

        f.writer.failNextWrite()
        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .failed)
        XCTAssertFalse(f.canMakeShare())
    }

    func testSuccessfulCloseDoesNotBlockTheNextShare() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()
        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertTrue(f.canMakeShare())
    }

    func testRepeatedCloseAndCancelledWaiterShareOneTeardown() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()

        f.writer.holdNextWrite()
        share.beginClose()
        let first = Task { await share.finishClose() }
        let second = Task { await share.finishClose() }
        let stepping = Task { await f.drain() }

        await f.writer.waitUntilBlocked()
        first.cancel()
        share.beginClose()
        f.writer.resume()

        let firstResult = await first.value
        let secondResult = await second.value
        await stepping.value
        let thirdResult = await share.finishClose()

        XCTAssertEqual(firstResult, .released)
        XCTAssertEqual(secondResult, .released)
        XCTAssertEqual(thirdResult, .released)
        XCTAssertEqual(f.wire, [.key(a, down: true), .key(a, down: false)], "teardown ran more than once")
    }

    func testDisconnectCompletesCloseWithoutClaimingRelease() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()

        f.conn.disconnect()
        share.beginClose()
        let result = await share.finishClose()

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(f.wire, [.key(a, down: true)])
    }

    func testDisconnectDuringReleaseCompletesTheWaiter() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()

        f.writer.holdNextWrite()
        share.beginClose()
        let closing = Task { await share.finishClose() }
        let stepping = Task { await f.drain() }
        await f.writer.waitUntilBlocked()

        f.conn.disconnect()
        let result = await closing.value
        f.writer.resume()
        await stepping.value

        XCTAssertEqual(result, .failed)
    }

    func testQueueClearDoesNotLoseCloseCompletion() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        _ = await f.step()

        share.beginClose()
        f.conn.clientToServerMessageQueue.clear()           // what the handshake does at framebuffer creation
        f.conn.enqueueClientCutTextMessage("unrelated")      // enqueued after the clear, must survive the close
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire, [.key(a, down: true), .key(a, down: false), .other(6)])
    }

    func testPreparedAndStaleHandlesNeverExecute() async {
        let f = Fixture()
        let stale = f.makeShare()

        XCTAssertFalse(stale.submit([.keyDown(1, a)]), "a prepared handle must not accept input")
        XCTAssertTrue(stale.activate())
        XCTAssertTrue(stale.submit([.keyDown(1, b)]))   // queued, then the share ends
        stale.beginClose()
        let staleResult = await stale.finishClose()
        XCTAssertEqual(staleResult, .released)

        XCTAssertFalse(stale.activate(), "a closed handle must never become active again")
        XCTAssertFalse(stale.submit([.keyDown(1, a)]))

        let fresh = f.makeShare()
        XCTAssertTrue(fresh.activate())
        XCTAssertTrue(fresh.submit([.keyDown(1, 0x63)]))
        await f.drain()

        XCTAssertEqual(f.wire, [.key(0x63, down: true)], "input of the previous share ran in the next one")

        fresh.beginClose()
        await f.drain()
        let freshResult = await fresh.finishClose()
        XCTAssertEqual(freshResult, .released)
        XCTAssertEqual(f.wire.last, .key(0x63, down: false))
    }

    // MARK: Fix regressions (existing API only)

    func testPreheldModifierSurvivesChordOfTheSameShare() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.syncModifiers([shift])]))
        _ = await f.step()

        XCTAssertTrue(share.submit([.chord([shift, a])]))
        await f.drain()

        XCTAssertEqual(f.wire, [.key(shift, down: true), .key(a, down: true), .key(a, down: false)],
                       "the chord released a modifier the share was already holding")

        // The modifier is still the share's, and the share's close releases it exactly once.
        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire.suffix(1), [.key(shift, down: false)])
        XCTAssertEqual(f.wire.filter({ $0 == .key(shift, down: false) }).count, 1)
    }

    func testChordPressesInOrderAndReleasesInReverse() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.chord([ctrl, alt, a])]))
        await f.drain()

        XCTAssertEqual(f.wire, [.key(ctrl, down: true), .key(alt, down: true), .key(a, down: true),
                                .key(a, down: false), .key(alt, down: false), .key(ctrl, down: false)])

        share.beginClose()
        await f.drain()
        let result = await share.finishClose()
        XCTAssertEqual(result, .released)
        XCTAssertEqual(f.wire.count, 6, "a finished chord leaves nothing to release")
    }

    func testChordKeepsKeysHeldByTheLocalHostAndByKeyDowns() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        f.conn.keyDown(VNCKeyCode(shift))
        XCTAssertTrue(share.submit([.keyDown(9, ctrl)]))
        await f.drain()

        XCTAssertTrue(share.submit([.chord([shift, ctrl, a])]))
        await f.drain()

        XCTAssertEqual(f.wire, [.key(shift, down: true), .key(ctrl, down: true),
                                .key(a, down: true), .key(a, down: false)])

        // Both stay down until their owners let go.
        XCTAssertTrue(share.submit([.keyUp(9)]))
        f.conn.keyUp(VNCKeyCode(shift))
        await f.drain()

        XCTAssertEqual(Array(f.wire.suffix(2)), [.key(ctrl, down: false), .key(shift, down: false)])
    }

    func testChordInterruptedByASendFailureStaysTheSharesResponsibility() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.chord([shift, a])]))
        f.writer.holdNextWrite()
        let stepping = Task { await f.drain() }
        await f.writer.waitUntilBlocked()
        f.writer.failNextWrite()
        f.writer.resume()
        await stepping.value

        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(f.wire, [.key(shift, down: true)])
    }

    func testSyncModifiersIsLevelTriggeredAndOwnsTheDiff() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.syncModifiers([shift, ctrl])]))
        XCTAssertTrue(share.submit([.syncModifiers([shift, ctrl])]))
        await f.drain()
        XCTAssertEqual(f.wire, [.key(shift, down: true), .key(ctrl, down: true)], "a repeated level pressed again")

        XCTAssertTrue(share.submit([.syncModifiers([ctrl, alt])]))
        await f.drain()
        XCTAssertEqual(Array(f.wire.suffix(2)), [.key(shift, down: false), .key(alt, down: true)])

        share.beginClose()
        await f.drain()
        let result = await share.finishClose()

        XCTAssertEqual(result, .released)
        XCTAssertEqual(Array(f.wire.suffix(2)), [.key(alt, down: false), .key(ctrl, down: false)],
                       "close releases in reverse press order")
    }

    func testSyncModifiersClaimsWhatTheLocalHostHoldsWithoutResendingIt() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        f.conn.keyDown(VNCKeyCode(shift))
        await f.drain()

        XCTAssertTrue(share.submit([.syncModifiers([shift])]))
        await f.drain()
        f.conn.keyUp(VNCKeyCode(shift))
        await f.drain()

        XCTAssertEqual(f.wire, [.key(shift, down: true)], "the local release took a modifier the share still holds")

        XCTAssertTrue(share.submit([.syncModifiers([])]))
        await f.drain()
        XCTAssertEqual(f.wire, [.key(shift, down: true), .key(shift, down: false)])
    }

    func testIndependentIdentitiesOfOneKeysymDoNotReleaseEachOther() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.keyDown(1, a), .keyDown(2, a)]))
        await f.drain()

        XCTAssertTrue(share.submit([.keyUp(2)]))
        await f.drain()
        XCTAssertEqual(f.wire, [.key(a, down: true), .key(a, down: true)],
                       "identity 2 released a keysym identity 1 still holds")

        XCTAssertTrue(share.submit([.keyUp(1)]))
        await f.drain()
        XCTAssertEqual(f.wire.last, .key(a, down: false))
        XCTAssertEqual(f.wire.filter({ $0 == .key(a, down: false) }).count, 1)
    }

    func testDisconnectWhileABatchExecutesWaitsForItAndSendsNoMore() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.move(5, 5), .keyDown(1, a)]))
        f.writer.holdNextWrite()
        let stepping = Task { await f.drain() }
        await f.writer.waitUntilBlocked()

        share.beginClose()
        f.conn.disconnect()

        let observed = Box<Outcome>()
        let closing = Task { () -> Outcome in
            let result = await share.finishClose()
            observed.set(result)
            return result
        }

        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(observed.value, "close completed while a write of its batch was still pending")

        f.writer.resume()
        await stepping.value
        let result = await closing.value

        XCTAssertEqual(f.wire, [.pointer(mask: 0, x: 5, y: 5)], "a DOWN left after the disconnect")
        XCTAssertEqual(result, .released, "nothing was put down, so nothing is left to release")
    }

    func testUnmatchedLocalKeyUpDoesNotReleaseAShareKey() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        await f.drain()

        f.conn.keyUp(VNCKeyCode(a))
        await f.drain()

        XCTAssertEqual(f.wire, [.key(a, down: true)], "a local UP without a local DOWN released the share's key")

        f.conn.keyUp(VNCKeyCode(b))
        await f.drain()
        XCTAssertEqual(f.wire.last, .key(b, down: false), "an unheld local UP has always been sent")
    }

    func testDisconnectDuringADownFailsTheCloseOnlyAfterTheWriteEnds() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        f.writer.holdNextWrite()
        let stepping = Task { await f.drain() }
        await f.writer.waitUntilBlocked()

        share.beginClose()
        f.conn.disconnect()

        let observed = Box<Outcome>()
        let closing = Task { () -> Outcome in
            let result = await share.finishClose()
            observed.set(result)
            return result
        }

        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(observed.value)

        f.writer.resume()
        await stepping.value
        let result = await closing.value

        XCTAssertEqual(result, .failed, "a DOWN of unknown outcome must not be reported as released")
    }

    func testSendLoopThatStopsWithoutDisconnectDoesNotHangClose() async {
        let f = Fixture()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())

        XCTAssertTrue(share.submit([.keyDown(1, a)]))
        await f.drain()

        // The connection is not ready, so the loop ends at once; nothing else will ever run the release.
        f.conn.startSendLoop()
        _ = await f.conn.sendTask?.result

        share.beginClose()

        let observed = Box<Outcome>()
        Task { observed.set(await share.finishClose()) }

        for _ in 0..<200 where observed.value == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(observed.value, .failed, "close never completed after the send loop was gone")
    }
}
// MARK: - Harness

/// Drives the connection's real send-loop step (`sendNext`) against a writer the test controls.
final class Fixture: @unchecked Sendable {
    let conn: VNCConnection
    let writer = ControlledWriter()

    init() {
        let encodings: [VNCFrameEncodingType] = []
        let settings = VNCConnection.Settings(isDebugLoggingEnabled: false,
                                              hostname: "127.0.0.1",
                                              port: 5900,
                                              isShared: true,
                                              isScalingEnabled: false,
                                              useDisplayLink: false,
                                              inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
                                              isClipboardRedirectionEnabled: false,
                                              colorDepth: .depth24Bit,
                                              frameEncodings: encodings)

        conn = VNCConnection(settings: settings, logger: VNCPrintLogger())
        conn.framebuffer = try! VNCFramebuffer(logger: conn.logger,
                                               size: VNCSize(width: 1000, height: 1000),
                                               screens: [ ],
                                               pixelFormat: VNCProtocol.PixelFormat(depth: 24),
                                               allocator: nil)
        conn.outboundWriter = writer
    }

    var wire: [Wire] { writer.events }

    /// Nothing sits between submit and the native FIFO any more.
    func flushMainHop() { }

    /// One iteration of the send loop body, with the loop's error handling.
    func step() async -> Bool {
        do {
            return try await conn.sendNext()
        } catch {
            conn.handleBreakingError(error)
            return true
        }
    }

    func drain() async {
        while await step() { }
    }

    func makeShare() -> Share { Share(try! conn.makeSharedInputSession()) }

    func canMakeShare() -> Bool {
        (try? conn.makeSharedInputSession()) != nil
    }
}

final class Share: @unchecked Sendable {
    private let session: VNCSharedInputSession

    init(_ session: VNCSharedInputSession) { self.session = session }

    func activate() -> Bool { session.activate() }

    func submit(_ ops: [Op]) -> Bool {
        session.submit(ops.map { op in
            switch op {
                case .keyDown(let identity, let keysym):
                    return .keyDown(VNCKeyCode(keysym), identity: identity)
                case .keyUp(let identity):
                    return .keyUp(identity: identity)
                case .move(let x, let y):
                    return .pointerMove(x: x, y: y)
                case .buttonDown(let button, let x, let y):
                    return .buttonDown(button, x: x, y: y)
                case .buttonUp(let button, let x, let y):
                    return .buttonUp(button, x: x, y: y)
                case .wheel(let wheel, let x, let y, let steps):
                    return .wheel(wheel, x: x, y: y, steps: steps)
                case .syncModifiers(let keysyms):
                    return .syncModifiers(keysyms.map({ VNCKeyCode($0) }))
                case .chord(let keysyms):
                    return .keyChord(keysyms.map({ VNCKeyCode($0) }))
            }
        })
    }

    func beginClose() { session.beginClose() }

    func finishClose() async -> Outcome {
        switch await session.finishClose() {
            case .released: return .released
            case .failed: return .failed
        }
    }
}

extension VNCSharedInputSessionTests {
    func testDesignBlockStaleLocalKeysymClaimSuppressesShareRelease() async {
        let f = Fixture()
        f.conn.keyDown(VNCKeyCode(0x48))
        await f.drain()
        f.conn.keyUp(VNCKeyCode(0x68))
        await f.drain()
        let share = f.makeShare()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit([.keyDown(1, 0x48)]))
        await f.drain()
        share.beginClose()
        await f.drain()
        let result = await share.finishClose()
        XCTAssertEqual(result, .released)
        XCTAssertTrue(f.wire.contains(.key(0x48, down: false)),
                      "stale local H ownership suppressed the share release while close reported success")
    }
}
