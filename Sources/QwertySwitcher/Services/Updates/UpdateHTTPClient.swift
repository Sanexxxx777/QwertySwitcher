import Foundation

/// Every network call the updater makes goes through here: ephemeral
/// session (no cookies/cache), two timeouts, a declared User-Agent, and a
/// hard cap on both the advertised `Content-Length` and the bytes actually
/// received — a compromised or misconfigured feed host does not get to hand
/// this process an unbounded download. One `UpdateHTTPClient` handles one
/// fetch at a time; callers create a fresh instance per request.
///
/// `timeout` = longest silence (no bytes) before giving up: a dead link.
/// `totalTimeout` = budget for the whole transfer, sized per caller to the
/// slowest link it should still serve. They were one value (15 s) until
/// 09.10.2026, which failed the ~4.8 MB archive on every link under
/// ~2.6 Mbit/s while bytes were still arriving.
final class UpdateHTTPClient: NSObject, URLSessionDataDelegate {
    enum ClientError: Error, Equatable {
        case tooLarge
        case badStatus(Int)
        case transport(String)
        case cancelled
    }

    private let maxBytes: Int
    let timeout: TimeInterval
    let totalTimeout: TimeInterval
    private let userAgent: String
    private var session: URLSession?
    private var buffer = Data()
    private var completion: ((Result<Data, ClientError>) -> Void)?
    private var finished = false

    /// The defaults fit the biggest thing this client fetches, the update
    /// archive (`maxBytes` is its 40 MB cap): 30 min lets the current
    /// ~4.8 MB zip finish at ~21 kbit/s. A small fetch passes a short
    /// `totalTimeout` of its own (the feed: 15 s).
    init(maxBytes: Int = 40_000_000, timeout: TimeInterval = 15, totalTimeout: TimeInterval = 30 * 60, userAgent: String) {
        self.maxBytes = maxBytes
        self.timeout = timeout
        self.totalTimeout = totalTimeout
        self.userAgent = userAgent
    }

    func fetch(_ url: URL, completion: @escaping (Result<Data, ClientError>) -> Void) {
        buffer = Data()
        finished = false
        self.completion = completion

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = totalTimeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(.transport("no HTTP response")))
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            finish(.failure(.badStatus(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > 0, http.expectedContentLength > Int64(maxBytes) {
            finish(.failure(.tooLarge))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if buffer.count > maxBytes {
            finish(.failure(.tooLarge))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // MINOR fix (security review): `session` used to just be dropped —
        // Apple's docs call `finishTasksAndInvalidate`/`invalidateAndCancel`
        // the correct way to release a delegate-based session's resources.
        defer {
            self.session = nil
            session.finishTasksAndInvalidate()
        }
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                // MINOR fix (security review): this used to `return` WITHOUT
                // calling `finish(...)`. That's a safe no-op for the ONE
                // cancellation this class triggers itself (the `.tooLarge`
                // path already calls `finish` before `dataTask.cancel()`, so
                // `finish`'s own `guard !finished` absorbs the duplicate) —
                // but any OTHER source of cancellation (system-level, a
                // future caller) left `completion` never called at all,
                // hanging whoever's waiting on it (`UpdateController` stuck
                // in `.checking` forever). Always resolve the callback.
                finish(.failure(.cancelled))
                return
            }
            finish(.failure(.transport(nsError.localizedDescription)))
            return
        }
        finish(.success(buffer))
    }

    private func finish(_ result: Result<Data, ClientError>) {
        guard !finished else { return }
        finished = true
        let callback = completion
        completion = nil
        callback?(result)
    }
}
