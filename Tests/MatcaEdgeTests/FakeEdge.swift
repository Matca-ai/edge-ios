import Foundation

/// The edge as a URLProtocol: routes keyed by "METHOD /path", every request recorded.
final class FakeEdge: URLProtocol {
    struct Route {
        let status: Int
        let body: Data
    }

    /// A route with this status fails the connection instead of answering.
    static let noConnection = -1
    /// A route with this status never answers, as an edge that hangs.
    static let neverAnswers = -2
    /// A route with this status answers a redirect to the elsewhere path.
    static let redirect = 302
    static let elsewhere = "/elsewhere"

    private static let lock = NSLock()
    private static var routes: [String: Route] = [:]
    private static var recordedRequests: [URLRequest] = []
    private static var requestObserver: (@Sendable () -> Void)?

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        recordedRequests = []
        requestObserver = nil
    }

    /// Runs when a request arrives, before it is answered.
    static func observeRequests(_ observer: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        requestObserver = observer
    }

    static func route(_ method: String, _ path: String, status: Int = 200, body: Data = Data()) {
        lock.lock()
        defer { lock.unlock() }
        routes["\(method) \(path)"] = Route(status: status, body: body)
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func requestedPaths(method: String) -> [String] {
        requests.filter { $0.httpMethod == method }.compactMap { $0.url?.path }
    }

    static func requests(endingWith suffix: String) -> [URLRequest] {
        requests.filter { $0.url?.path.hasSuffix(suffix) == true }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeEdge.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (route, observer) = Self.record(request)
        observer?()
        if route.status == Self.neverAnswers { return }
        if route.status == Self.noConnection {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.status == Self.redirect ? ["Location": Self.elsewhere] : nil)!
        if route.status == Self.redirect {
            var moved = request
            moved.url = URL(string: Self.elsewhere, relativeTo: request.url)?.absoluteURL
            client?.urlProtocol(self, wasRedirectedTo: moved, redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func record(_ request: URLRequest) -> (Route, (@Sendable () -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(withBody(request))
        let route = routes["\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"] ?? Route(status: 404, body: Data())
        return (route, requestObserver)
    }

    /// URLSession hands a protocol the body as a stream; the tests read it as data.
    private static func withBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        stream.open()
        defer { stream.close() }
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            body.append(buffer, count: read)
        }
        var withBody = request
        withBody.httpBody = body
        return withBody
    }
}
