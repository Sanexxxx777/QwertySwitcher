import Foundation

/// Every network call the updater makes goes through here: ephemeral
/// session (no cookies/cache), a fixed timeout, a declared User-Agent, and a
/// hard cap on both the advertised `Content-Length` and the bytes actually
/// received — a compromised or misconfigured feed host does not get to hand
/// this process an unbounded download. One `UpdateHTTPClient` handles one
/// fetch at a time; callers create a fresh instance per request.
final class UpdateHTTPClient: NSObject, URLSessionDataDelegate {
    enum ClientError: Error, Equatable {
        case tooLarge
        case badStatus(Int)
        case transport(String)
    }

    private let maxBytes: Int
    private let timeout: TimeInterval
    private let userAgent: String
    private var session: URLSession?
    private var buffer = Data()
    private var completion: ((Result<Data, ClientError>) -> Void)?
    private var finished = false

    init(maxBytes: Int = 40_000_000, timeout: TimeInterval = 15, userAgent: String) {
        self.maxBytes = maxBytes
        self.timeout = timeout
        self.userAgent = userAgent
    }

    func fetch(_ url: URL, completion: @escaping (Result<Data, ClientError>) -> Void) {
        buffer = Data()
        finished = false
        self.completion = completion

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
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
        defer { self.session = nil }
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return } // already reported by finish()
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
