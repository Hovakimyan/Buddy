@preconcurrency import CloudKit
import Foundation
import Synchronization

/// In-memory stand-in for the private database: one zone, a version counter as the change token,
/// server-side modification dates, and the CloudKit behaviours the transport relies on. No network,
/// no `CKContainer`.
final class FakeCloudDatabase: CloudDatabase {
    enum Op: Hashable { case saveZone, save, delete, saveSubscription, changes }

    private struct Stored {
        var record: CKRecord
        var version: Int
        var modifiedAt: Date
    }

    private struct State {
        var zoneExists = false
        var records: [CKRecord.ID: Stored] = [:]
        var version = 0
        var deletions: [(id: CKRecord.ID, recordType: String, version: Int)] = []
        var subscriptions: [String: CKSubscription] = [:]
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var failures: [Op: [Error]] = [:]
        var calls: [Op: Int] = [:]
        var lastSavePolicy: CKModifyRecordsOperation.RecordSavePolicy?
        /// Records whose per-item result in a zone fetch is a failure (CloudKit reports those per record).
        var poisoned: Set<CKRecord.ID> = []
    }

    private let state = Mutex(State())

    // MARK: Test controls

    /// The next `times` calls of `op` throw `error`.
    func fail(_ op: Op, with error: Error, times: Int = 1) {
        state.withLock { $0.failures[op, default: []].append(contentsOf: Array(repeating: error, count: times)) }
    }

    func dropZone() {
        state.withLock {
            $0.zoneExists = false
            $0.records = [:]
        }
    }

    /// From now on a zone fetch reports this record as a per-item failure instead of delivering it.
    func poison(_ id: CKRecord.ID) { state.withLock { _ = $0.poisoned.insert(id) } }

    func setNow(_ date: Date) { state.withLock { $0.now = date } }

    func calls(_ op: Op) -> Int { state.withLock { $0.calls[op, default: 0] } }
    var zoneExists: Bool { state.withLock { $0.zoneExists } }
    var lastSavePolicy: CKModifyRecordsOperation.RecordSavePolicy? { state.withLock { $0.lastSavePolicy } }
    var subscriptions: [String: CKSubscription] { state.withLock { $0.subscriptions } }

    /// The stored record, as CloudKit would hand it back.
    func record(named name: String) -> CKRecord? {
        state.withLock { state in state.records.first { $0.key.recordName == name }?.value.record }
    }

    func recordNames(ofType type: String? = nil) -> Set<String> {
        state.withLock { state in
            Set(state.records.filter { type == nil || $0.value.record.recordType == type }.map(\.key.recordName))
        }
    }

    /// Puts a record in the zone directly, as another device (or an attacker) could.
    func inject(_ record: CKRecord) {
        state.withLock { state in
            state.zoneExists = true
            state.version += 1
            state.records[record.recordID] = Stored(record: record, version: state.version, modifiedAt: state.now)
        }
    }

    // MARK: CloudDatabase

    private func enter(_ op: Op) throws {
        try state.withLock { state in
            state.calls[op, default: 0] += 1
            if var queue = state.failures[op], !queue.isEmpty {
                let error = queue.removeFirst()
                state.failures[op] = queue
                throw error
            }
        }
    }

    func saveZone(_ zone: CKRecordZone) async throws {
        try enter(.saveZone)
        state.withLock { $0.zoneExists = true }
    }

    func save(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        try enter(.save)
        try state.withLock { state in
            guard state.zoneExists else { throw CKError(.zoneNotFound) }
            state.lastSavePolicy = policy
            for record in records {
                if policy == .ifServerRecordUnchanged, let stored = state.records[record.recordID] {
                    // Like CloudKit, the error carries the record that is already there.
                    throw CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: stored.record])
                }
                state.version += 1
                state.records[record.recordID] = Stored(
                    record: record, version: state.version, modifiedAt: state.now)
            }
        }
    }

    func delete(_ ids: [CKRecord.ID]) async throws {
        try enter(.delete)
        try state.withLock { state in
            guard state.zoneExists else { throw CKError(.zoneNotFound) }
            for id in ids {
                guard let removed = state.records.removeValue(forKey: id) else { continue }
                state.version += 1
                state.deletions.append((id, removed.record.recordType, state.version))
            }
        }
    }

    func save(subscription: CKSubscription) async throws {
        try enter(.saveSubscription)
        state.withLock { $0.subscriptions[subscription.subscriptionID] = subscription }
    }

    func changes(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> ZoneChanges {
        try enter(.changes)
        return try state.withLock { state in
            guard state.zoneExists else { throw CKError(.zoneNotFound) }
            let since = token.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
            var result = ZoneChanges()
            let modifications = state.records.values.sorted(by: { $0.version < $1.version })
                .filter { $0.version > since }
                .map { stored -> (id: CKRecord.ID, result: Result<ChangedRecord, Error>) in
                    state.poisoned.contains(stored.record.recordID)
                        ? (stored.record.recordID, .failure(CKError(.internalError)))
                        : (stored.record.recordID, .success(ChangedRecord(record: stored.record, modifiedAt: stored.modifiedAt)))
                }
            result.absorb(modifications: modifications)
            for deletion in state.deletions where deletion.version > since {
                result.deletions.append((deletion.id, deletion.recordType))
            }
            result.token = Data(String(state.version).utf8)
            return result
        }
    }
}

/// Collects what an `AsyncStream` yields, so tests can wait for values without sleeping blindly.
final class Collector<T: Sendable>: Sendable {
    private final class Box: Sendable {
        let values = Mutex<[T]>([])
        let task = Mutex<Task<Void, Never>?>(nil)
    }

    private let box = Box()

    init(_ stream: AsyncStream<T>) {
        let box = box
        let task = Task {
            for await value in stream { box.values.withLock { $0.append(value) } }
        }
        box.task.withLock { $0 = task }
    }

    deinit { box.task.withLock { $0?.cancel() } }

    var all: [T] { box.values.withLock { $0 } }

    /// Waits until `condition` holds for the collected values (an upper bound only).
    @discardableResult
    func wait(timeout: Duration = .seconds(10), until condition: ([T]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(all) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition(all)
    }
}

/// Polls `condition` until it holds (an upper bound only).
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
