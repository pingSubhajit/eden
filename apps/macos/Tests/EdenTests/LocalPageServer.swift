import Darwin
import Foundation

/// A loopback-only HTTP origin serving a fixed table of pages, for tests that
/// need a page and its neighbours on a real http address. Anything not in
/// the table is a 404 page, as a real site's would be.
final class LocalPageServer {
    struct Page {
        var status = "200 OK"
        var type: String
        var body: String
        var withoutLength = false
        var slowly = false
        /// Never kept, as a signed-in site's pages often aren't: going back
        /// to one asks the site again rather than taking it from the cache.
        var uncached = false
        /// Never answered: the request is held until the server stops, and
        /// then dropped, as a page on a connection that goes away is.
        var hangs = false
    }

    private let socket: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var asked: [String] = []
    private var heardAll: [Heard] = []
    private var sentBodies: [String: Int] = [:]
    private var stopped = false
    private let pages: [String: Page]
    let port: UInt16

    private let acceptQueue = DispatchQueue(label: "eden.page-fixture.accept")
    private let clientsQueue = DispatchQueue(label: "eden.page-fixture.clients", attributes: .concurrent)

    /// `port`: none for any free one, or one a stopped server had, to stand
    /// in for a site that comes back where it was.
    init(_ pages: [String: Page], port wanted: UInt16 = 0) throws {
        self.pages = pages
        let server = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { throw Self.failure("socket") }
        socket = server

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(server, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = wanted.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(server, 8) == 0 else {
            Darwin.close(server)
            throw Self.failure("bind/listen")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
        }
        guard named == 0 else {
            Darwin.close(server)
            throw Self.failure("getsockname")
        }
        port = UInt16(bigEndian: actual.sin_port)

        source = DispatchSource.makeReadSource(fileDescriptor: server, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
    }

    deinit { stop() }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    /// Every path asked for, in order.
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    /// A request as it came: how, where, and what it carried.
    struct Heard: Equatable {
        var method: String
        var path: String
        var body: String
    }

    /// Every request, in order, with its method and body.
    var heard: [Heard] {
        lock.lock()
        defer { lock.unlock() }
        return heardAll
    }

    func bytesSent(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sentBodies[path] ?? 0
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        guard first else { return }
        source.cancel()
        shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func acceptOne() {
        let client = Darwin.accept(socket, nil, nil)
        guard client >= 0 else { return }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        clientsQueue.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024, data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<end.lowerBound], encoding: .utf8),
              let line = header.components(separatedBy: "\r\n").first?.split(separator: " "),
              line.count > 1
        else { return }
        let method = String(line[0])
        let target = line[1]
        let path = URLComponents(string: "http://fixture\(target)")?.path ?? String(target)
        // The body, as long as the request says it is. A body sent in
        // chunks, or one that stops short, isn't one this server can say it
        // heard, and goes unanswered.
        let fields = header.components(separatedBy: "\r\n").dropFirst().map { $0.lowercased() }
        guard !fields.contains(where: { $0.hasPrefix("transfer-encoding:") && $0.contains("chunked") }) else { return }
        let length = fields
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        var carried = Data(data[end.upperBound...])
        while carried.count < length {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            carried.append(contentsOf: buffer.prefix(count))
        }
        lock.lock()
        asked.append(path)
        heardAll.append(Heard(method: method, path: path, body: String(decoding: carried, as: UTF8.self)))
        lock.unlock()

        let page = pages[path] ?? Page(status: "404 Not Found", type: "text/html",
                                       body: "<!doctype html><title>Not found</title><p>Nothing here</p>")
        if page.hangs {
            while !isStopped { usleep(20_000) }
            return
        }
        let body = Data(page.body.utf8)
        let head = "HTTP/1.1 \(page.status)\r\n"
            + "Content-Type: \(page.type)\r\n"
            + (page.withoutLength ? "" : "Content-Length: \(body.count)\r\n")
            + (page.uncached ? "Cache-Control: no-store\r\n" : "")
            + "Connection: close\r\n\r\n"
        guard send(client, Data(head.utf8)) else { return }
        if !page.slowly {
            _ = send(client, body)
            return
        }
        for start in stride(from: 0, to: body.count, by: 16 * 1024) {
            let end = min(start + 16 * 1024, body.count)
            guard send(client, body.subdata(in: start..<end)) else { return }
            lock.lock()
            sentBodies[path] = end
            lock.unlock()
            usleep(1000)
        }
    }

    private func send(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(client, base.advanced(by: sent), raw.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func failure(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed"])
    }
}
