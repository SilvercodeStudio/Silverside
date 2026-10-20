import Foundation
import Testing

@testable import CDRipKit

/// Answers requests from a list, in order, and keeps the requests.
actor FakeTransport: HTTPTransport {
    enum Answer {
        case status(Int, body: String = "", headers: [String: String] = [:])
        case timeout
    }

    var answers: [Answer]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let answer = answers.isEmpty ? .status(500) : answers.removeFirst()
        switch answer {
        case .timeout:
            throw URLError(.timedOut)
        case .status(let code, let body, let headers):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

struct WebClientTests {
    static let url = URL(string: "https://example.org/a")!

    /// A client with its own cache folder and short delays, so tests are fast.
    func client(_ transport: FakeTransport, interval: Duration = .zero, lifetime: Duration = .seconds(3600))
        -> (WebClient, URL)
    {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CDRipTests-\(UUID())")
        let client = WebClient(
            directory: directory, transport: transport,
            policies: ["example.org": .init(interval: interval, lifetime: lifetime)], firstRetryDelay: .milliseconds(10)
        )
        return (client, directory)
    }

    @Test func keepsResponsesInTheCache() async throws {
        let transport = FakeTransport([.status(200, body: "abc")])
        let (client, directory) = client(transport)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.data(from: Self.url) == Data("abc".utf8))
        #expect(try await client.data(from: Self.url) == Data("abc".utf8))
        #expect(await client.requestsSent == 1)
    }

    @Test func keepsNotFoundInTheCache() async throws {
        let transport = FakeTransport([.status(404)])
        let (client, directory) = client(transport)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.data(from: Self.url) == nil)
        #expect(try await client.data(from: Self.url) == nil)
        #expect(await client.requestsSent == 1)
    }

    @Test func asksAgainWhenTheCacheIsOldOrNotWanted() async throws {
        let transport = FakeTransport([.status(200, body: "1"), .status(200, body: "2"), .status(200, body: "3")])
        let (client, directory) = client(transport, lifetime: .zero)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.data(from: Self.url) == Data("1".utf8))
        #expect(try await client.data(from: Self.url) == Data("2".utf8))
        #expect(try await client.data(from: Self.url, useCache: false) == Data("3".utf8))
    }

    @Test func triesAgainWhenTheServerIsBusy() async throws {
        let transport = FakeTransport([
            .status(503, headers: ["Retry-After": "0"]), .status(429), .timeout, .status(200, body: "ok"),
        ])
        let (client, directory) = client(transport)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.data(from: Self.url) == Data("ok".utf8))
        #expect(await client.requestsSent == 4)
    }

    @Test func givesUpAfterTheLastAttempt() async throws {
        let transport = FakeTransport(Array(repeating: .status(503), count: WebClient.maximumAttempts))
        let (client, directory) = client(transport)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: OnlineLookupError.self) { try await client.data(from: Self.url) }
        #expect(await client.requestsSent == WebClient.maximumAttempts)
    }

    @Test func doesNotTryAgainAfterOtherErrors() async throws {
        let transport = FakeTransport([.status(500)])
        let (client, directory) = client(transport)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: OnlineLookupError.httpStatus(500, Self.url)) { try await client.data(from: Self.url) }
    }

    @Test func usesAnOldCopyWhenTheRequestFails() async throws {
        let failures = Array(repeating: FakeTransport.Answer.timeout, count: WebClient.maximumAttempts)
        let transport = FakeTransport([.status(200, body: "old")] + failures)
        let (client, directory) = client(transport, lifetime: .zero)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.data(from: Self.url) == Data("old".utf8))
        #expect(try await client.data(from: Self.url) == Data("old".utf8))
        #expect(await client.requestsSent == 1 + WebClient.maximumAttempts)
    }

    /// Two clients that share a folder stand for two processes: the limit holds for both.
    @Test func waitsBetweenRequestsToAHost() async throws {
        let transport = FakeTransport([.status(200), .status(200), .status(200)])
        let (first, directory) = client(transport, interval: .milliseconds(300))
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = WebClient(
            directory: directory, transport: transport,
            policies: ["example.org": .init(interval: .milliseconds(300), lifetime: .seconds(3600))])
        let start = ContinuousClock.now
        _ = try await first.data(from: URL(string: "https://example.org/1")!)
        _ = try await first.data(from: URL(string: "https://example.org/2")!)
        _ = try await second.data(from: URL(string: "https://example.org/3")!)
        #expect(ContinuousClock.now - start >= .milliseconds(600))
    }

    @Test func namesItselfToTheServer() async throws {
        let transport = FakeTransport([.status(200)])
        let (client, directory) = client(transport)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await client.data(from: Self.url)
        let agent = await transport.requests.first?.value(forHTTPHeaderField: "User-Agent")
        #expect(agent == "CDRip/\(CDRipVersion.string) ( https://preston-landers.github.io/CDRip )")
    }

    @Test func waitsTwoSecondsBetweenMusicBrainzRequests() {
        #expect(WebClient.defaultPolicies["musicbrainz.org"]?.interval == .seconds(2))
    }
}
