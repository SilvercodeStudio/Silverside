import CryptoKit
import Foundation

/// Sends one HTTP request. `URLSessionTransport` sends real ones; tests use a fake.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// Fetches data from web services politely, for every part of CDRip.
///
/// - Each host has a rate limit, kept in a file under a lock, so that it holds
///   across `cdrip` processes as well as within one.
/// - A 503, a 429, or a timeout is tried again later: after `Retry-After` if the
///   server gives it, or with a delay that doubles each time.
/// - Responses, and 404s, are kept in a cache on disk, for a time that depends on the host.
///   When a request fails, a copy from the cache is used even if it is old, so that
///   lookups work offline.
public actor WebClient {
    public static let userAgent = "CDRip/\(CDRipVersion.string) ( https://preston-landers.github.io/CDRip )"

    /// How CDRip treats one host.
    public struct HostPolicy: Sendable {
        /// The shortest time between two requests to the host.
        public var interval: Duration
        /// How long a response stays in the cache.
        public var lifetime: Duration

        public init(interval: Duration, lifetime: Duration) {
            self.interval = interval
            self.lifetime = lifetime
        }
    }

    static let day = Duration.seconds(86_400)

    /// MusicBrainz allows 1 request per second on average, but answered 503 to requests
    /// 1.5 s apart (perhaps at a busy time of day), so CDRip waits 2 s. The others have
    /// no published limit.
    public static let defaultPolicies: [String: HostPolicy] = [
        "musicbrainz.org": HostPolicy(interval: .seconds(2), lifetime: day * 7),
        "coverartarchive.org": HostPolicy(interval: .seconds(1), lifetime: day * 30),
        "www.accuraterip.com": HostPolicy(interval: .milliseconds(200), lifetime: day),
        "db.cuetools.net": HostPolicy(interval: .milliseconds(200), lifetime: day),
        // An entry's repair data never changes.
        "p.cuetools.net": HostPolicy(interval: .milliseconds(200), lifetime: day * 365),
    ]
    static let fallbackPolicy = HostPolicy(interval: .seconds(1), lifetime: day)

    /// A 404 is kept this long, because a disc can be added to a database.
    public static let notFoundLifetime = day

    public static let maximumAttempts = 4

    public static let shared = WebClient(
        directory: URL.cachesDirectory.appending(path: "CDRip", directoryHint: .isDirectory))

    let transport: any HTTPTransport
    let directory: URL
    let policies: [String: HostPolicy]
    let firstRetryDelay: Duration

    /// The number of requests sent to the transport, for tests.
    public private(set) var requestsSent = 0

    public init(
        directory: URL, transport: any HTTPTransport = URLSessionTransport(),
        policies: [String: HostPolicy] = defaultPolicies, firstRetryDelay: Duration = .seconds(2)
    ) {
        self.directory = directory
        self.transport = transport
        self.policies = policies
        self.firstRetryDelay = firstRetryDelay
    }

    /// The response body for `url`, or nil if the server answers 404.
    /// `useCache: false` sends a new request, and keeps its answer in the cache. If the
    /// request fails, the answer in the cache is used, however old it is.
    public func data(from url: URL, useCache: Bool = true) async throws -> Data? {
        let key = Insecure.SHA1.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let body = directory.appending(path: "web/\(key).data")
        let meta = directory.appending(path: "web/\(key).json")
        let policy = policies[url.host() ?? ""] ?? Self.fallbackPolicy

        let cached = (try? JSONDecoder().decode(CacheEntry.self, from: Data(contentsOf: meta))).flatMap {
            entry -> (entry: CacheEntry, data: Data?)? in
            if entry.status == 404 { return (entry, nil) }
            return (try? Data(contentsOf: body)).map { (entry, $0) }
        }
        if useCache, let cached {
            let age = Duration.seconds(Date().timeIntervalSince(cached.entry.fetched))
            if age < (cached.entry.status == 404 ? Self.notFoundLifetime : policy.lifetime) { return cached.data }
        }

        let data: Data
        let status: Int
        do {
            (data, status) = try await fetch(url, policy: policy)
        } catch {
            if let cached { return cached.data }
            throw error
        }
        try FileManager.default.createDirectory(at: body.deletingLastPathComponent(), withIntermediateDirectories: true)
        if status == 200 { try data.write(to: body, options: .atomic) }
        try JSONEncoder().encode(CacheEntry(url: url.absoluteString, status: status, fetched: Date()))
            .write(to: meta, options: .atomic)
        return status == 404 ? nil : data
    }

    struct CacheEntry: Codable {
        var url: String
        var status: Int
        var fetched: Date
    }

    /// Sends the request, waiting for the host's rate limit, and tries again when the server is busy.
    private func fetch(_ url: URL, policy: HostPolicy) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var delay = firstRetryDelay
        for attempt in 1...Self.maximumAttempts {
            try await waitForTurn(host: url.host() ?? "", interval: policy.interval)
            requestsSent += 1
            do {
                let (data, response) = try await transport.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 || status == 404 { return (data, status) }
                guard status == 503 || status == 429, attempt < Self.maximumAttempts else {
                    throw OnlineLookupError.httpStatus(status, url)
                }
                let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Double($0) }
                try await Task.sleep(for: retryAfter.map { .seconds($0) } ?? delay)
            } catch let error as URLError where error.code == .timedOut && attempt < Self.maximumAttempts {
                try await Task.sleep(for: delay)
            }
            delay *= 2
        }
        throw OnlineLookupError.httpStatus(503, url)
    }

    /// Waits until `interval` has passed since the last request to `host` from any
    /// CDRip process. The time of the last request is kept in a file. The file's lock is
    /// held only while the time is read or written, never while this waits, so a second
    /// request in this process (a rip in another drive) waits in its own task rather
    /// than in `flock`, which would hold a thread.
    private func waitForTurn(host: String, interval: Duration) async throws {
        let folder = directory.appending(path: "rate", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = open(folder.appending(path: host.isEmpty ? "unknown" : host).path, O_RDWR | O_CREAT, 0o644)
        guard file >= 0 else { return }
        defer { close(file) }
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        while true {
            flock(file, LOCK_EX)
            var buffer = [UInt8](repeating: 0, count: 32)
            let count = pread(file, &buffer, buffer.count, 0)
            let last = count > 0 ? Double(String(decoding: buffer.prefix(count), as: UTF8.self)) ?? 0 : 0
            let wait = last + seconds - Date().timeIntervalSince1970
            if wait <= 0 {
                let now = Array(String(Date().timeIntervalSince1970).utf8)
                ftruncate(file, 0)
                _ = pwrite(file, now, now.count, 0)
                flock(file, LOCK_UN)
                return
            }
            flock(file, LOCK_UN)
            try await Task.sleep(for: .seconds(wait))
        }
    }
}

/// The version that CDRip reports, as in its User-Agent.
public enum CDRipVersion {
    public static let string = "0.3"
}
