import Foundation

/// What a request says about where it came from, used to pick the store it belongs to.
public struct DumpHint: Equatable, Sendable {
    /// Source files of the payloads (absolute paths as the client saw them).
    public var files: [String]
    /// Project name or application path sent by the client, when any.
    public var projectName: String?
    public var hostname: String?
    /// Request uuid (`uuid`, or `id` for ds()); follow-up calls reuse it.
    public var uuid: String?

    public init(files: [String] = [], projectName: String? = nil, hostname: String? = nil, uuid: String? = nil) {
        self.files = files
        self.projectName = projectName
        self.hostname = hostname
        self.uuid = uuid
    }
}

/// Maps HTTP requests onto stores. Routes:
/// POST payloads, `POST /api/dumps`, `GET /locks/:lockName`, `GET /windows`, `GET /theme`.
@MainActor
public final class DumpRouter {
    /// Picks the store a request goes to.
    public var storeFor: (DumpHint) -> DumpStore
    /// Every store, used to answer lock polls and `/windows`.
    public var allStores: () -> [DumpStore]
    public var themeProvider: () -> String = { "system" }

    public init(storeFor: @escaping (DumpHint) -> DumpStore, allStores: @escaping () -> [DumpStore]) {
        self.storeFor = storeFor
        self.allStores = allStores
    }

    /// Single-store routing.
    public convenience init(store: DumpStore) {
        self.init(storeFor: { _ in store }, allStores: { [store] })
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204)
        }

        if request.method == "GET" || request.method == "HEAD" {
            if request.path.hasPrefix("/locks/") {
                let name = String(request.path.dropFirst("/locks/".count))
                let stores = allStores()
                let owner = stores.first { $0.locks[name] != nil } ?? stores.first
                return .json(owner?.lockResponse(name) ?? ["active": false, "stop_execution": false])
            }
            if request.path == "/windows" {
                // One window per project/hostname session.
                var names: [String] = []
                for store in allStores() {
                    for name in store.knownProjects where !names.contains(name) { names.append(name) }
                }
                let projects = names.map { JSONValue.object(JSONObject([("project_name", .string($0))])) }
                return .json(.array(projects))
            }
            if request.path == "/theme" {
                return .json(["theme": .string(themeProvider())])
            }
        }

        // ds() clients: POST /api/dumps. The client only counts a send as delivered when the reply
        // has an `id` that is a valid UUID.
        if request.method == "POST" && request.path == "/api/dumps" {
            do {
                let json = try JSONValue.parse(request.body)
                let batch = json.array ?? [json]
                for payload in batch {
                    storeFor(Self.dsHint(payload)).ingestDsPayload(payload)
                }
                let id = json["id"]?.string.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() } ?? UUID().uuidString.lowercased()
                return .json(["id": .string(id)])
            } catch {
                return .text("Invalid JSON: \(error)", status: 400)
            }
        }

        if request.method == "POST" && (request.path == "/" || request.path.isEmpty) {
            do {
                let json = try JSONValue.parse(request.body)
                // Accept a single request object or an array of them.
                let batch = json.array ?? [json]
                for item in batch {
                    storeFor(Self.hint(item)).ingest(item)
                }
                return .json(["status": "ok"])
            } catch {
                return .text("Invalid JSON: \(error)", status: 400)
            }
        }

        // Unknown routes answer 404. The PHP client probes `/_availability_check` with
        // CURLOPT_FAILONERROR and only counts a 404 as "app is running", so keep this a 404.
        return .text("Cannot \(request.method) \(request.path)", status: 404)
    }

    /// Hint for a `{uuid, payloads, meta}` request.
    static func hint(_ request: JSONValue) -> DumpHint {
        let origins = (request["payloads"]?.array ?? []).map { Origin(json: $0["origin"]) }
        let project = request["meta"]?["project_name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return DumpHint(files: origins.compactMap(\.file),
                        projectName: project,
                        hostname: origins.lazy.compactMap(\.hostname).first,
                        uuid: request["uuid"]?.string)
    }

    /// Hint for a ds() payload.
    static func dsHint(_ payload: JSONValue) -> DumpHint {
        let origin = DumpStore.dsOrigin(payload["ide_handle"])
        let app = payload["application_path"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return DumpHint(files: origin.file.map { [$0] } ?? [], projectName: app, hostname: origin.hostname,
                        uuid: payload["id"]?.string)
    }
}
