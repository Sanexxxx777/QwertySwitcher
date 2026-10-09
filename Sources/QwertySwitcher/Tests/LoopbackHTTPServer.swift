#if DEBUG
import Foundation
import Darwin

/// One-shot HTTP/1.1 server on 127.0.0.1 (ephemeral port) for the updater's
/// HTTP-client tests: answers the first request with `bodySize` zero bytes,
/// `chunkSize` at a time, sleeping `gap` between chunks — a slow but alive
/// link. `stallAfterFirstChunk` instead sends one chunk and then goes silent
/// for that long — a dead link. Loopback only; nothing leaves the machine.
final class LoopbackHTTPServer {
    let url: URL
    private let listenFD: Int32

    init?(bodySize: Int, chunkSize: Int, gap: TimeInterval, stallAfterFirstChunk: TimeInterval? = nil) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, sa, &length) == 0
            }
        }
        guard bound, let url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: addr.sin_port))/update.zip") else {
            close(fd)
            return nil
        }
        self.url = url
        self.listenFD = fd

        let thread = Thread {
            Self.serveOnce(listenFD: fd, bodySize: bodySize, chunkSize: chunkSize, gap: gap, stall: stallAfterFirstChunk)
        }
        thread.start()
    }

    /// Unblocks a pending `accept` if the client never connected.
    func stop() {
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    private static func serveOnce(listenFD: Int32, bodySize: Int, chunkSize: Int, gap: TimeInterval, stall: TimeInterval?) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        // The client may hang up mid-body (that is what a timeout looks like
        // from here): a write to it must fail with EPIPE, not kill the test
        // process with SIGPIPE.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var request = [UInt8]()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while !request.ends(with: Array("\r\n\r\n".utf8)) {
            let n = read(client, &scratch, scratch.count)
            guard n > 0 else { return }
            request.append(contentsOf: scratch[0..<n])
        }

        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: \(bodySize)\r\nConnection: close\r\n\r\n"
        guard writeAll(client, Array(header.utf8)) else { return }
        let chunk = [UInt8](repeating: 0, count: chunkSize)
        var sent = 0
        while sent < bodySize {
            let n = min(chunkSize, bodySize - sent)
            guard writeAll(client, Array(chunk[0..<n])) else { return }
            sent += n
            if let stall {
                Thread.sleep(forTimeInterval: stall)
                return
            }
            Thread.sleep(forTimeInterval: gap)
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}
#endif
