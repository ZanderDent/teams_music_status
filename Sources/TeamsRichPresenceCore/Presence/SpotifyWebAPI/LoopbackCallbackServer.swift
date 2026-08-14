import Foundation
import Network

/// A single-use loopback HTTP listener that catches the OAuth redirect.
///
/// Bound to `127.0.0.1` only — never `0.0.0.0` — so nothing off-device can reach it, and
/// it is torn down the moment the callback arrives (or the flow is cancelled). The
/// authorization code it receives is passed straight to the token exchange and is never
/// logged.
public final class LoopbackCallbackServer {

    private let port: UInt16
    private let path: String
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var finished = false

    public init(port: UInt16, path: String) {
        self.port = port
        self.path = path.isEmpty ? "/" : path
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only.
        parameters.requiredInterfaceType = .loopback

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SpotifyAuth.AuthError.portUnavailable(port)
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    public func stop() {
        lock.lock()
        let pending = connections
        connections = []
        lock.unlock()
        pending.forEach { $0.cancel() }
        listener?.cancel()
        listener = nil
    }

    /// Wait for the redirect. Returns the query parameters (`code`/`state`, or `error`).
    public func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(with: .failure(SpotifyAuth.AuthError.timedOut))
                }
            }
        } onCancel: {
            self.finish(with: .failure(SpotifyAuth.AuthError.cancelled))
        }
    }

    private func finish(with result: Result<[String: String], Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()

        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            self.handle(request: request, on: connection)
        }
    }

    private func handle(request: String, on connection: NWConnection) {
        // Request line: "GET /callback?code=...&state=... HTTP/1.1"
        guard let requestLine = request.split(separator: "\r\n").first else {
            respond(connection, status: "400 Bad Request", body: "Malformed request.")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(connection, status: "400 Bad Request", body: "Malformed request.")
            return
        }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == path else {
            // Browsers cheerfully ask for /favicon.ico; don't let that end the flow.
            respond(connection, status: "404 Not Found", body: "Not found.")
            return
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }

        let succeeded = values["code"] != nil
        respond(connection,
                status: "200 OK",
                body: succeeded
                    ? "Spotify connected. You can close this tab and return to Teams Rich Presence."
                    : "Sign-in was not completed. You can close this tab and try again.",
                isHTML: true)
        finish(with: .success(values))
    }

    private func respond(_ connection: NWConnection, status: String, body: String, isHTML: Bool = false) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Teams Rich Presence</title></head>\
        <body style="font:16px -apple-system,system-ui,sans-serif;padding:3rem;color:#1d1d1f">\
        <h2 style="font-weight:600">Teams Rich Presence</h2><p>\(body)</p></body></html>
        """
        let payload = isHTML ? html : body
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: \(isHTML ? "text/html; charset=utf-8" : "text/plain; charset=utf-8")\r
        Content-Length: \(payload.utf8.count)\r
        Connection: close\r
        \r
        \(payload)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
