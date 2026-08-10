import Foundation
import XCTest
@testable import CodexCompanionCore

final class PairingCoordinatorTests: XCTestCase {
    final class Store: PairingRecordStore {
        var records: [String: PairingRecord] = [:]
        var saves = 0
        func save(_ record: PairingRecord) throws { saves += 1; records[record.hostID] = record }
        func remove(hostID: String) throws { records.removeValue(forKey: hostID) }
    }

    func testPersistsOnlyAfterSASConfirmation() throws {
        let store = Store()
        let candidate = PairingCandidate(id: "mac-1", displayName: "Office Mac", endpoint: "192.168.1.2:4567")
        let coordinator = PairingCoordinator(store: store, sasProvider: { _ in "123456" })
        try coordinator.beginRecovery(candidate: candidate, pairingSecret: Data(repeating: 1, count: 32), peerPublicKey: Data(repeating: 2, count: 32))
        XCTAssertEqual(store.saves, 0)
        try coordinator.confirm(sas: "123456")
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(coordinator.phase, .paired(store.records["mac-1"]!))
    }

    func testWrongSASClearsPendingAndLeavesNoRecord() throws {
        let store = Store()
        let coordinator = PairingCoordinator(store: store, sasProvider: { _ in "123456" })
        try coordinator.beginRecovery(candidate: PairingCandidate(id: "m", displayName: "Mac"), pairingSecret: Data(repeating: 0, count: 32), peerPublicKey: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try coordinator.confirm(sas: "654321")) { error in
            XCTAssertEqual(error as? PairingCoordinatorError, .invalidSAS)
        }
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(coordinator.phase, .failed(.invalidSAS))
    }

    func testExpiryAndCancelDoNotLeaveHalfPairedState() throws {
        let store = Store()
        var clock = Date(timeIntervalSince1970: 100)
        let coordinator = PairingCoordinator(store: store, now: { clock }, sasProvider: { _ in "123456" })
        try coordinator.beginRecovery(candidate: PairingCandidate(id: "m", displayName: "Mac"), pairingSecret: Data(repeating: 0, count: 32), peerPublicKey: Data(repeating: 1, count: 32), timeout: 1)
        clock = Date(timeIntervalSince1970: 102)
        XCTAssertThrowsError(try coordinator.confirm(sas: "123456"))
        XCTAssertEqual(store.saves, 0)
        coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .idle)
    }
}
