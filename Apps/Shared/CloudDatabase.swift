@preconcurrency import CloudKit
import Foundation
import OSLog

/// A record as returned by a zone-changes fetch, with the server's modification time (trustworthy,
/// unlike any date field a writer put in the record).
struct ChangedRecord: @unchecked Sendable {
    var record: CKRecord
    var modifiedAt: Date?
}

struct ZoneChanges: @unchecked Sendable {
    var records: [ChangedRecord] = []
    var deletions: [(id: CKRecord.ID, recordType: String)] = []
    /// Opaque, archived `CKServerChangeToken`; nil when the fetch returned none.
    var token: Data?
    /// Records the server listed but could not deliver (per-item errors). They are skipped, never fatal:
    /// failing the whole fetch would keep the change token from advancing and stall every consumer.
    var skippedCount = 0

    private static let log = Logger(subsystem: "com.sergeyhovakimyan.buddy", category: "cloudkit")

    /// Adds one page of modification results, skipping (and logging, error code only) per-record failures.
    mutating func absorb(modifications: [(id: CKRecord.ID, result: Result<ChangedRecord, Error>)]) {
        for modification in modifications {
            switch modification.result {
            case .success(let changed):
                records.append(changed)
            case .failure(let error):
                skippedCount += 1
                Self.log.error("skipped a record in a zone fetch (CloudKit error code \((error as NSError).code))")
            }
        }
    }
}

/// The few private-database operations `CloudKitTransport` needs. `CKDatabaseAdapter` is the real one;
/// tests use an in-memory fake, so no test ever creates a `CKContainer`.
protocol CloudDatabase: Sendable {
    func saveZone(_ zone: CKRecordZone) async throws
    /// Throws the first per-record error.
    func save(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws
    /// Deleting a record that does not exist is not an error.
    func delete(_ ids: [CKRecord.ID]) async throws
    func save(subscription: CKSubscription) async throws
    /// Every change after `token` (nil: every record), following `moreComing` to the end.
    func changes(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> ZoneChanges
}

/// How the transport reacts to a CloudKit error.
enum CloudKitFailure: Equatable {
    /// The `Buddy` zone does not exist (yet): create it and retry.
    case zoneNotFound
    /// Deleting something that is already gone.
    case unknownItem
    /// A save that was not allowed to overwrite found a record already there.
    case serverRecordChanged
    /// The saved change token is stale: restart from scratch.
    case changeTokenExpired
    /// Transient (network, rate limit, service): fail so the caller retries. `after` is the server's hint.
    case retryable(after: TimeInterval?)
    case other

    /// The record already on the server that made a save fail with `serverRecordChanged` (looked up inside a
    /// partial failure too), when CloudKit sent it.
    static func serverRecord(of error: Error) -> CKRecord? {
        guard let error = error as? CKError else { return nil }
        if let record = error.serverRecord { return record }
        if error.code == .partialFailure, let first = error.partialErrorsByItemID?.values.first {
            return serverRecord(of: first)
        }
        return nil
    }

    static func classify(_ error: Error) -> CloudKitFailure {
        guard let error = error as? CKError else { return .other }
        switch error.code {
        case .partialFailure:
            // One item failed (we only ever modify one kind of thing at a time): classify its error.
            if let first = error.partialErrorsByItemID?.values.first { return classify(first) }
            return .other
        // The user deleted the Buddy data from iCloud settings: same remedy, recreate the zone.
        case .zoneNotFound, .userDeletedZone: return .zoneNotFound
        case .unknownItem: return .unknownItem
        case .serverRecordChanged: return .serverRecordChanged
        case .changeTokenExpired: return .changeTokenExpired
        case .networkUnavailable, .networkFailure, .serverResponseLost, .requestRateLimited,
            .serviceUnavailable, .zoneBusy:
            return .retryable(after: error.retryAfterSeconds)
        default: return .other
        }
    }
}

/// `CloudDatabase` over a real `CKDatabase` (the private database), using the async CloudKit API.
struct CKDatabaseAdapter: CloudDatabase {
    let database: CKDatabase

    func saveZone(_ zone: CKRecordZone) async throws {
        let (saved, _) = try await database.modifyRecordZones(saving: [zone], deleting: [])
        for result in saved.values { _ = try result.get() }
    }

    func save(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        let (saved, _) = try await database.modifyRecords(
            saving: records, deleting: [], savePolicy: policy, atomically: false)
        for result in saved.values { _ = try result.get() }
    }

    func delete(_ ids: [CKRecord.ID]) async throws {
        let (_, deleted) = try await database.modifyRecords(saving: [], deleting: ids, atomically: false)
        for result in deleted.values {
            do { try result.get() } catch where CloudKitFailure.classify(error) == .unknownItem { continue }
        }
    }

    func save(subscription: CKSubscription) async throws {
        let (saved, _) = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        for result in saved.values { _ = try result.get() }
    }

    func changes(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> ZoneChanges {
        var cursor = try token.flatMap(Self.unarchive)
        var all = ZoneChanges()
        while true {
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: cursor)
            all.absorb(
                modifications: page.modificationResultsByID.map { id, result in
                    (id, result.map { ChangedRecord(record: $0.record, modifiedAt: $0.record.modificationDate) })
                })
            for deletion in page.deletions { all.deletions.append((deletion.recordID, deletion.recordType)) }
            cursor = page.changeToken
            all.token = try Self.archive(page.changeToken)
            if !page.moreComing { return all }
        }
    }

    private static func archive(_ token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data) throws -> CKServerChangeToken? {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
