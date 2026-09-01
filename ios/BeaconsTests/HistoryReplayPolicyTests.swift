import XCTest
@testable import Beacons

final class HistoryReplayPolicyTests: XCTestCase {
    func testCleanDrainMayCheckpointHighestReceivedSequence() {
        XCTAssertEqual(
            historyEndDisposition(received: 100, expected: 100, resyncAttempts: 0, resyncCap: 2),
            .complete)
    }

    func testWireGapRetriesOnlyWithinThisConnectionsBudget() {
        XCTAssertEqual(
            historyEndDisposition(received: 99, expected: 100, resyncAttempts: 1, resyncCap: 2),
            .retryNow)
        XCTAssertEqual(
            historyEndDisposition(received: 99, expected: 100, resyncAttempts: 2, resyncCap: 2),
            .deferIncomplete)
    }

    func testLostBeginNeverFinalizesAStaleGenerationEvenForAnEmptyDrain() {
        // A board wipe can change generation while the begin notify is lost. end(n: 0) matching
        // received=0 is therefore NOT proof that the old tuple may be checkpointed.
        XCTAssertEqual(historyEndDisposition(
            received: 0, expected: 0, resyncAttempts: 0, resyncCap: 2,
            beginSeen: false), .retryNow)
        XCTAssertEqual(historyEndDisposition(
            received: 0, expected: 0, resyncAttempts: 2, resyncCap: 2,
            beginSeen: false), .deferIncomplete)
        XCTAssertFalse(historyEnvelopeAuthorizesCheckpoint(beginSeen: false))
    }

    func testMatchingEmptyDrainWithItsBeginMayFinalize() {
        XCTAssertEqual(historyEndDisposition(
            received: 0, expected: 0, resyncAttempts: 0, resyncCap: 2,
            beginSeen: true), .complete)
        XCTAssertTrue(historyEnvelopeAuthorizesCheckpoint(beginSeen: true))
    }

    func testIncompleteAttemptDisclosesAllObservableShortfall() {
        XCTAssertEqual(replayUnreplayedCount(
            promised: 100, sent: 100, received: 99, transportComplete: false), 1)
        XCTAssertEqual(replayUnreplayedCount(
            promised: 100, sent: 99, received: 99, transportComplete: true), 1)
        XCTAssertEqual(replayUnreplayedCount(
            promised: 100, sent: 99, received: 98, transportComplete: false), 2)
        XCTAssertEqual(replayUnreplayedCount(
            promised: 100, sent: 100, received: 101, transportComplete: false), 1)
    }

    func testReplayGenerationUsesExactNonzeroUInt32Lexeme() {
        XCTAssertEqual(Detection.exactWireUInt32(
            forKey: "gen", in: Data(#"{"hist":"begin","gen":42}"#.utf8)), 42)
        for raw in [
            #"{"hist":"begin","gen":1.0000000000000000001}"#,
            #"{"hist":"begin","gen":4294967296}"#,
            #"{"hist":"begin","gen":42,"gen":43}"#,
            #"{"hist":"begin","gen":42,"g\u0065n":43}"#,
        ] {
            XCTAssertNil(Detection.exactWireUInt32(forKey: "gen", in: Data(raw.utf8)), raw)
        }
    }
}
