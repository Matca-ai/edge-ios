import Foundation

enum DeliveryCount: String {
    case installs
    case failedChecks = "failed-checks"
}

/// The client side of the edge's API (the contract's section 2).
protocol Delivery: Sendable {
    func manifest() async throws -> SignedManifest
    func file(release: Int, platform: String, path: String, expectedSize: Int) async throws -> Data
    func count(_ event: DeliveryCount, release: Int) async throws
    /// A day's counts for that release since the report before, as JSON (the contract's section 11).
    func report(_ body: Data, release: Int) async throws
}

/// A redirect is answered as the status it is, as the Android library does.
private final class RedirectsRefused: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class EdgeDelivery: Delivery {
    private static let manifestLimitBytes = 1 << 20

    private let modelURL: URL
    private let configuration: EdgeConfiguration
    private let session: URLSession
    private let redirectsRefused = RedirectsRefused()

    init(model: String, configuration: EdgeConfiguration, session: URLSession) {
        modelURL = configuration.baseURL.appendingPathComponent("v1/models/\(model)")
        self.configuration = configuration
        self.session = session
    }

    /// URLSession has no separate connect timeout: the 60 s request timeout bounds the connect as well.
    static func makeSession() -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.waitsForConnectivity = false
        return URLSession(configuration: sessionConfiguration)
    }

    func manifest() async throws -> SignedManifest {
        let data = try await body(
            of: request(modelURL.appendingPathComponent("manifest")), atMost: Self.manifestLimitBytes,
            tooLong: .unreadableManifest("the answer is over 1 MiB")
        )
        do {
            return try JSONDecoder().decode(SignedManifest.self, from: data)
        } catch {
            throw EdgeError.unreadableManifest("the edge's answer is not a signed manifest")
        }
    }

    func file(release: Int, platform: String, path: String, expectedSize: Int) async throws -> Data {
        var fileRequest = request(releaseURL(release).appendingPathComponent("files/\(platform)/\(path)"))
        fileRequest.allowsCellularAccess = !configuration.wifiOnly
        return try await body(of: fileRequest, atMost: expectedSize, tooLong: .fileMismatch(path: path))
    }

    func count(_ event: DeliveryCount, release: Int) async throws {
        var countRequest = request(releaseURL(release).appendingPathComponent(event.rawValue))
        countRequest.httpMethod = "POST"
        try await post(countRequest)
    }

    func report(_ body: Data, release: Int) async throws {
        var reportRequest = request(releaseURL(release).appendingPathComponent("report"))
        reportRequest.httpMethod = "POST"
        reportRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reportRequest.httpBody = body
        try await post(reportRequest)
    }

    private func post(_ request: URLRequest) async throws {
        let response = try await answering { try await session.data(for: request, delegate: redirectsRefused).1 }
        try requireSuccess(response)
    }

    /// A longer body than the limit is wrong whatever it holds, so it is not read on.
    private func body(of request: URLRequest, atMost limit: Int, tooLong: EdgeError) async throws -> Data {
        try await answering {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectsRefused)
            try requireSuccess(response)
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= limit else { throw tooLong }
            }
            return data
        }
    }

    /// A failed connection is the edge not answering, what the Android library calls it too.
    private func answering<Answered>(_ exchange: () async throws -> Answered) async throws -> Answered {
        do {
            return try await exchange()
        } catch is URLError {
            throw EdgeError.edge(status: 0)
        }
    }

    private func releaseURL(_ release: Int) -> URL {
        modelURL.appendingPathComponent("releases/\(release)")
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.deliveryKey)", forHTTPHeaderField: "Authorization")
        request.setValue(EdgeLibrary.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw EdgeError.edge(status: 0) }
        guard (200..<300).contains(http.statusCode) else { throw EdgeError.edge(status: http.statusCode) }
    }
}
