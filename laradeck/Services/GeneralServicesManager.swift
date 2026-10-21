import Foundation
import Observation

/// A standalone Docker Compose stack not tied to a project (Mailpit, Gotenberg, MinIO…).
/// Laradeck keeps its own copy of the YAML in `<root>/<folderName>/compose.yaml`; the folder
/// name doubles as the Compose project name.
nonisolated struct GeneralService: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var folderName: String
    /// First `image:` in the YAML, used to pick an icon.
    var image: String?
    /// `docker compose up -d` when Laradeck launches (once Docker is running).
    var autoStart: Bool = false

    init(id: UUID = UUID(), name: String, folderName: String, image: String? = nil, autoStart: Bool = false) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.image = image
        self.autoStart = autoStart
    }

    // services.json written before autoStart existed has no such key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        folderName = try c.decode(String.self, forKey: .folderName)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}

nonisolated enum GeneralServiceError: LocalizedError {
    case invalid(String)
    case dockerUnavailable

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .dockerUnavailable: return "Docker isn't running — start Docker Desktop to use services."
        }
    }
}

@MainActor
@Observable
final class GeneralServicesManager {
    private(set) var services: [GeneralService] = []
    /// Containers per service from `docker compose ps`.
    private(set) var statuses: [UUID: [DockerServiceStatus]] = [:]
    private(set) var busy: Set<UUID> = []
    var error: String?

    let root: URL
    private let docker: DockerManager
    private var refreshTask: Task<Void, Never>?
    /// Autostart runs once per launch, the first time Docker is seen running.
    private var didAutoStart = false

    init(docker: DockerManager, root: URL? = nil) {
        self.docker = docker
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Laradeck/Services", isDirectory: true)
        services = loadList()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Paths

    private var listURL: URL { root.appendingPathComponent("services.json") }
    func folder(for service: GeneralService) -> URL { root.appendingPathComponent(service.folderName, isDirectory: true) }
    func composeURL(for service: GeneralService) -> URL { folder(for: service).appendingPathComponent("compose.yaml") }

    func service(id: UUID) -> GeneralService? { services.first { $0.id == id } }

    func yaml(for service: GeneralService) -> String {
        (try? String(contentsOf: composeURL(for: service), encoding: .utf8)) ?? ""
    }

    // MARK: Status

    func containers(_ service: GeneralService) -> [DockerServiceStatus] { statuses[service.id] ?? [] }
    func isRunning(_ service: GeneralService) -> Bool { containers(service).contains(where: \.isRunning) }
    var runningCount: Int { services.filter(isRunning).count }

    func refresh() async {
        guard docker.isDaemonRunning else { return }
        for service in services {
            let status = await docker.composeStatus(projectPath: folder(for: service).path)
            if statuses[service.id] != status { statuses[service.id] = status }
        }
        if !didAutoStart {
            didAutoStart = true
            for service in services where service.autoStart && !isRunning(service) {
                start(service)
            }
        }
    }

    func setAutoStart(_ service: GeneralService, _ on: Bool) {
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return }
        services[index].autoStart = on
        saveList()
    }

    // MARK: Add / edit

    /// Checks the YAML with `docker compose config`; returns the error text, or nil when valid.
    func validate(_ yaml: String) async -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("laradeck-validate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try yaml.write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        let result = await docker.composeQuery(["config", "--quiet"], projectPath: dir.path, mergeStderr: true)
        if result.success { return nil }
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "docker compose couldn't read this YAML (is Docker running?)" : message
    }

    @discardableResult
    func add(name: String, yaml: String, autoStart: Bool = false) async throws -> GeneralService {
        if let problem = await validate(yaml) { throw GeneralServiceError.invalid(problem) }
        let typed = name.trimmingCharacters(in: .whitespaces)
        let fromYAML = Self.firstServiceName(in: yaml) ?? "service"
        let name = typed.isEmpty ? fromYAML.prefix(1).uppercased() + fromYAML.dropFirst() : typed
        let service = GeneralService(name: name, folderName: uniqueFolderName(for: name),
                                     image: Self.firstImage(in: yaml), autoStart: autoStart)
        try FileManager.default.createDirectory(at: folder(for: service), withIntermediateDirectories: true)
        try yaml.write(to: composeURL(for: service), atomically: true, encoding: .utf8)
        services.append(service)
        saveList()
        return service
    }

    /// Imports a dropped / chosen compose file (a copy is kept).
    @discardableResult
    func importFile(_ url: URL) async throws -> GeneralService {
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let fileName = url.deletingPathExtension().lastPathComponent
        // "docker-compose (1)" says nothing; prefer the service name inside.
        let generic = fileName.lowercased().hasPrefix("docker-compose") || fileName.lowercased().hasPrefix("compose")
        return try await add(name: generic ? "" : fileName, yaml: yaml)
    }

    /// Saves new YAML; a running stack is updated with `up -d` so the change applies.
    func update(_ service: GeneralService, name: String, yaml: String) async throws {
        if let problem = await validate(yaml) { throw GeneralServiceError.invalid(problem) }
        try yaml.write(to: composeURL(for: service), atomically: true, encoding: .utf8)
        if let index = services.firstIndex(where: { $0.id == service.id }) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { services[index].name = trimmed }
            services[index].image = Self.firstImage(in: yaml)
            saveList()
        }
        if isRunning(service) { start(service) }
    }

    // MARK: Actions

    func start(_ service: GeneralService) { compose(service, ["up", "-d", "--remove-orphans"]) }
    func stop(_ service: GeneralService) { compose(service, ["stop"]) }
    func restart(_ service: GeneralService) { compose(service, ["restart"]) }

    func toggle(_ service: GeneralService) {
        if isRunning(service) { stop(service) } else { start(service) }
    }

    /// `down` (optionally removing named volumes), then forgets the service and its folder.
    func delete(_ service: GeneralService, removeVolumes: Bool) {
        let args = removeVolumes ? ["down", "-v", "--remove-orphans"] : ["down", "--remove-orphans"]
        compose(service, args) { [weak self] in
            guard let self else { return }
            try? FileManager.default.trashItem(at: self.folder(for: service), resultingItemURL: nil)
            self.services.removeAll { $0.id == service.id }
            self.statuses[service.id] = nil
            self.saveList()
        }
    }

    func logTail(_ service: GeneralService, lines: Int = 60) async -> String {
        await docker.composeQuery(["logs", "--no-color", "--tail", String(lines)],
                                  projectPath: folder(for: service).path, mergeStderr: true).output
    }

    private func compose(_ service: GeneralService, _ arguments: [String], then: (() -> Void)? = nil) {
        guard docker.isDaemonRunning else {
            error = DockerManager.daemonUnavailableMessage
            return
        }
        busy.insert(service.id)
        error = nil
        Task {
            let result = await docker.composeQuery(arguments, projectPath: folder(for: service).path, mergeStderr: true)
            if !result.success {
                error = "\(service.displayName): " + result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            busy.remove(service.id)
            then?()
            await refresh()
        }
    }

    // MARK: Persistence

    private func loadList() -> [GeneralService] {
        guard let data = try? Data(contentsOf: listURL) else { return [] }
        return (try? JSONDecoder().decode([GeneralService].self, from: data)) ?? []
    }

    private func saveList() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(services).write(to: listURL, options: .atomic)
        } catch {
            self.error = "Couldn't save services: \(error.localizedDescription)"
        }
    }

    /// Compose project names allow lowercase letters, digits, `-` and `_`.
    private func uniqueFolderName(for name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        let base = "laradeck-" + (slug.isEmpty ? "service" : slug)
        var candidate = base
        var n = 2
        let taken = Set(services.map(\.folderName))
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    // MARK: YAML peeking (no full parser needed for a name and an icon)

    nonisolated static func firstServiceName(in yaml: String) -> String? {
        var inServices = false
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inServices = trimmed.hasPrefix("services:")
                continue
            }
            if inServices, trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                return String(trimmed.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    nonisolated static func firstImage(in yaml: String) -> String? {
        for raw in yaml.split(separator: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("image:") else { continue }
            let value = trimmed.dropFirst("image:".count).trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}

extension GeneralService {
    /// Shown in the UI: first letter uppercase ("mailpit" → "Mailpit"), the rest as typed.
    var displayName: String {
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    /// SF Symbol for well-known images, a box otherwise.
    var systemImage: String {
        let image = (image ?? name).lowercased()
        if image.contains("mailpit") || image.contains("mailhog") || image.contains("smtp") { return "envelope.fill" }
        if image.contains("gotenberg") || image.contains("pdf") { return "doc.richtext.fill" }
        if image.contains("meilisearch") || image.contains("typesense") || image.contains("elastic") { return "magnifyingglass" }
        if image.contains("minio") || image.contains("s3") { return "externaldrive.fill" }
        if image.contains("soketi") || image.contains("reverb") { return "dot.radiowaves.left.and.right" }
        if image.contains("selenium") || image.contains("chrome") { return "globe" }
        return "shippingbox.fill"
    }
}
