import CryptoKit
import Foundation

enum CloudMeter: String, Sendable {
    case volcengineTranslation = "volcengine-translate"
    case aliyunTranslation = "aliyun-translate"
    case volcengineOCR = "volcengine-ocr"
    case aliyunOCR = "aliyun-ocr"

    var account: CloudAccount {
        switch self {
        case .volcengineTranslation, .volcengineOCR: .volcengine
        case .aliyunTranslation, .aliyunOCR: .aliyun
        }
    }

    var title: String {
        switch self {
        case .volcengineTranslation, .aliyunTranslation: "\(account.title)机器翻译月用量"
        case .volcengineOCR: "火山引擎 OCR 累计用量"
        case .aliyunOCR: "阿里云 OCR 月用量"
        }
    }

    var limit: Decimal {
        switch self {
        case .volcengineTranslation: 2_000_000
        case .aliyunTranslation: 1_000_000
        case .volcengineOCR: 5_000
        case .aliyunOCR: 200
        }
    }

    var unit: String {
        switch self {
        case .volcengineTranslation, .aliyunTranslation: "字符"
        case .volcengineOCR, .aliyunOCR: "次"
        }
    }

    func detail(_ used: Decimal) -> String {
        let format = Decimal.FormatStyle.number.precision(.fractionLength(0...2))
        switch self {
        case .volcengineTranslation, .aliyunTranslation:
            return "\((used / 10_000).formatted(format)) / \((limit / 10_000).formatted(format)) 万字符"
        case .volcengineOCR, .aliyunOCR:
            return "\(used.formatted(format)) / \(limit.formatted(format)) 次"
        }
    }

    func read(_ credentials: CloudCredentials) async throws -> (used: Decimal, note: String?) {
        switch self {
        case .volcengineTranslation: (try await Volcengine.translationQuota.read(credentials), nil)
        case .aliyunTranslation: (try await Aliyun.translationQuota.read(credentials), nil)
        case .aliyunOCR: (try await Aliyun.ocrQuota.read(credentials), nil)
        case .volcengineOCR: try await VolcengineOCR.usage.read(credentials)
        }
    }

    func storage(for credentials: CloudCredentials) -> URL {
        let fingerprint = CloudDigest.hex(SHA256.hash(data: Data(credentials.accessKey.utf8)))
        return CloudCredentials.directory.appendingPathComponent("Usage", isDirectory: true)
            .appendingPathComponent("\(rawValue)-\(fingerprint).json")
    }
}

enum CloudBilling {
    static let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }()

    static func period(at date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }

    static func monthStart(at date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }
}

actor MonthlyQuota {
    typealias Query = @Sendable (CloudCredentials, Date) async throws -> Decimal

    private struct Record: Codable {
        let month: String
        var used: Decimal
    }

    private let meter: CloudMeter
    private let query: Query
    private let storage: @Sendable (CloudCredentials) -> URL
    private var lastRefresh: (credentials: CloudCredentials, month: String, date: Date)?
    private let queue = SerialWorkQueue()

    init(_ meter: CloudMeter, query: @escaping Query,
         storage: (@Sendable (CloudCredentials) -> URL)? = nil) {
        self.meter = meter
        self.query = query
        self.storage = storage ?? meter.storage
    }

    func read(_ credentials: CloudCredentials) async throws -> Decimal {
        try await queue.run { try await self.readUsage(credentials) }
    }

    private func readUsage(_ credentials: CloudCredentials) async throws -> Decimal {
        let now = Date.now
        let url = storage(credentials)
        return try await refresh(load(url, now: now), at: url, credentials: credentials, now: now)
    }

    func send<Value: Sendable>(
        _ credentials: CloudCredentials, amount: Int, operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await queue.run { try await self.sendReserved(credentials, amount: amount, operation: operation) }
    }

    private func sendReserved<Value: Sendable>(
        _ credentials: CloudCredentials, amount: Int, operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let url = storage(credentials)
        while true {
            try Task.checkCancellation()
            let now = Date.now
            var record = try load(url, now: now)
            try requireCapacity(record.used, amount: amount)
            do {
                record.used = try await refresh(record, at: url, credentials: credentials, now: now)
            } catch {
                try Task.checkCancellation()
                throw CloudFailure("无法确认\(meter.title)，已跳过请求。\(error.localizedDescription)")
            }
            guard record.month == CloudBilling.period(at: .now) else { continue }
            try Task.checkCancellation()
            try requireCapacity(record.used, amount: amount)
            let previous = record
            record.used += Decimal(amount)
            // Persist before dispatch so delayed reports and restarts retain the reservation.
            try save(record, to: url)
            do {
                return try await operation()
            } catch let error as CloudRejected {
                try save(previous, to: url)
                throw error
            }
        }
    }

    private func requireCapacity(_ used: Decimal, amount: Int) throws {
        if used >= meter.limit {
            throw CloudFailure("\(meter.title)已达到额度（\(meter.limit.formatted()) \(meter.unit)），已跳过请求。")
        }
        if used + Decimal(amount) > meter.limit {
            throw CloudFailure("本次请求超过剩余额度（\((meter.limit - used).formatted()) \(meter.unit)），已跳过请求。")
        }
    }

    private func refresh(_ record: Record, at url: URL, credentials: CloudCredentials, now: Date) async throws -> Decimal {
        if let refresh = lastRefresh, refresh.credentials == credentials, refresh.month == record.month,
           (0..<60).contains(now.timeIntervalSince(refresh.date)) { return record.used }

        let observed = try await query(credentials, now)
        try Task.checkCancellation()
        let used = max(record.used, observed)
        if used > record.used { try save(Record(month: record.month, used: used), to: url) }
        lastRefresh = (credentials, record.month, now)
        return used
    }

    private func load(_ url: URL, now: Date) throws -> Record {
        let month = CloudBilling.period(at: now)
        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
            if record.month == month { return record }
        } catch CocoaError.fileReadNoSuchFile {}
        return Record(month: month, used: 0)
    }

    private func save(_ record: Record, to url: URL) throws {
        try CloudCredentials.write(JSONEncoder().encode(record), to: url)
    }
}

actor VolcengineOCRUsage {
    typealias Query = @Sendable (CloudCredentials, Date, Date) async throws -> Set<String>

    private struct History: Codable {
        let beginsAt: Date
        var synchronizedThrough: Date?
        var ids: Set<String> = []
    }

    private struct State {
        let url: URL
        var history: History
        var pending: Set<String>
        var persistedThrough: Date?
        var checkedAt: Date?
        var auditError: String?
        var count: Decimal { Decimal(history.ids.count + pending.count) }
        var pendingURL: URL { url.appendingPathExtension("pending") }
    }

    private let query: Query
    private let storage: @Sendable (CloudCredentials) -> URL
    private let queue = SerialWorkQueue()
    private var state: State?
    private var credentials: CloudCredentials?

    init(query: @escaping Query, storage: (@Sendable (CloudCredentials) -> URL)? = nil) {
        self.query = query
        self.storage = storage ?? CloudMeter.volcengineOCR.storage
    }

    func read(_ credentials: CloudCredentials) async throws -> (used: Decimal, note: String?) {
        try await queue.run { try await self.readUsage(credentials) }
    }

    private func readUsage(_ credentials: CloudCredentials) async throws -> (used: Decimal, note: String?) {
        var current = try load(credentials, now: .now)
        defer { state = current }
        try await refresh(&current, credentials: credentials, now: .now)
        let note = current.auditError.map {
            "审计暂不可用，显示已记录用量。\n\($0)"
        }
        return (current.count, note)
    }

    func send(_ credentials: CloudCredentials, operation: @escaping @Sendable () async throws -> (id: String?, text: String)) async throws -> String {
        try await queue.run { try await self.sendTracked(credentials, operation: operation) }
    }

    private func sendTracked(
        _ credentials: CloudCredentials, operation: @Sendable () async throws -> (id: String?, text: String)
    ) async throws -> String {
        var current = try load(credentials, now: .now)
        defer { state = current }
        try requireCapacity(current)
        try await refresh(&current, credentials: credentials, now: .now)
        try requireCapacity(current)
        try Task.checkCancellation()
        let result = try await operation()
        if let id = result.id, !id.isEmpty, !current.history.ids.contains(id), !current.pending.contains(id) {
            var pending = current.pending
            pending.insert(id)
            try save(pending, to: current.pendingURL)
            current.pending = pending
            if pending.count >= 64 {
                var history = current.history
                history.ids.formUnion(pending)
                try update(&current, history: history)
            }
        }
        try Task.checkCancellation()
        return result.text
    }

    private func requireCapacity(_ current: State) throws {
        let limit = CloudMeter.volcengineOCR.limit
        guard current.count < limit else {
            throw CloudFailure("火山引擎 OCR 累计用量已达到 \(limit.formatted()) 次，已跳过请求。")
        }
    }

    private func refresh(_ current: inout State, credentials: CloudCredentials, now: Date) async throws {
        if let date = current.checkedAt, (0..<60).contains(now.timeIntervalSince(date)) { return }
        let start = current.history.beginsAt
        let overlap = current.history.synchronizedThrough?.addingTimeInterval(-86_400) ?? start
        let begin = max(overlap, start, now.addingTimeInterval(-90 * 86_400 + 300))
        let observed: Set<String>
        do {
            observed = try await query(credentials, begin, now)
        } catch {
            try Task.checkCancellation()
            current.auditError = error.localizedDescription
            current.checkedAt = now
            return
        }

        try Task.checkCancellation()
        let hasNewIDs = !observed.isSubset(of: current.history.ids)
        if hasNewIDs || now.timeIntervalSince(current.persistedThrough ?? .distantPast) >= 86_400 {
            var history = current.history
            if hasNewIDs { history.ids.formUnion(observed) }
            history.synchronizedThrough = now
            try update(&current, history: history)
        } else {
            // Advance live queries even when an unchanged checkpoint need not be written.
            current.history.synchronizedThrough = now
        }
        current.auditError = nil
        current.checkedAt = now
    }

    private func update(_ current: inout State, history: History) throws {
        try save(history, to: current.url)
        current.history = history
        current.persistedThrough = history.synchronizedThrough
        let pending = current.pending.subtracting(history.ids)
        guard pending != current.pending else { return }
        current.pending = pending
        try save(pending, to: current.pendingURL)
    }

    private func load(_ credentials: CloudCredentials, now: Date) throws -> State {
        let url = storage(credentials)
        if var state, state.url == url {
            if self.credentials != credentials { state.checkedAt = nil }
            self.credentials = credentials
            return state
        }
        var history: History
        do {
            history = try JSONDecoder().decode(History.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            history = History(beginsAt: CloudBilling.monthStart(at: now), synchronizedThrough: nil)
            try save(history, to: url)
        }
        var current = State(url: url, history: history, pending: [], persistedThrough: history.synchronizedThrough)
        do {
            let pending = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: current.pendingURL))
            current.pending = pending.subtracting(history.ids)
        } catch CocoaError.fileReadNoSuchFile {}
        self.credentials = credentials
        return current
    }

    private func save(_ value: some Encodable, to url: URL) throws {
        try CloudCredentials.write(JSONEncoder().encode(value), to: url)
    }
}
