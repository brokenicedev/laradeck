import Foundation
import Network

/// Small HTTP/1.1 server on Network.framework. One request per connection, like the PHP/JS clients use it.
public final class HTTPServer: @unchecked Sendable {
    public enum State: Equatable {
        case stopped
        case starting(port: UInt16)
        case running(port: UInt16)
        case failed(port: UInt16, message: String)
    }

    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// Large dumps are allowed, but capped to protect memory.
    public var maxRequestBytes = 512 * 1024 * 1024
    public var onStateChange: (@Sendable (State) -> Void)?

    private let handler: Handler
    private let queue = DispatchQueue(label: "laradeck.dumps.http")
    private var listener: NWListener?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start(port: UInt16) {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            report(.starting(port: port))
            guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else {
                report(.failed(port: port, message: "Invalid port \(port)"))
                return
            }
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: nwPort)
                l.stateUpdateHandler = { [weak self, weak l] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.report(.running(port: port))
                    case .failed(let error):
                        self.report(.failed(port: port, message: Self.describe(error)))
                        l?.cancel()
                    case .waiting(let error):
                        self.report(.failed(port: port, message: Self.describe(error)))
                        l?.cancel()
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener = l
                l.start(queue: queue)
            } catch {
                report(.failed(port: port, message: "\(error)"))
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            report(.stopped)
        }
    }

    private func report(_ state: State) { onStateChange?(state) }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port is already in use (is another debug viewer running?)"
        }
        return "\(error)"
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), sentContinue: false)
    }

    private func receive(on connection: NWConnection, buffer: Data, sentContinue: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > self.maxRequestBytes {
                self.send(.text("Payload too large", status: 413), on: connection)
                return
            }
            switch HTTPParser.parse(buffer) {
            case .complete(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            case .invalid(let reason):
                self.send(.text(reason, status: 400), on: connection)
            case .incomplete(let expectsContinue):
                if error != nil || isComplete { connection.cancel(); return }
                var sent = sentContinue
                if expectsContinue && !sent {
                    // curl sends "Expect: 100-continue" for larger bodies and waits for this.
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    sent = true
                }
                self.receive(on: connection, buffer: buffer, sentContinue: sent)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}
