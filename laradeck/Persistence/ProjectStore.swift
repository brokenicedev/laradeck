import Foundation

/// JSON-backed persistence for projects and global command presets.
/// SwiftData would be a natural upgrade if the data model grows (spec §59).
struct ProjectStore {
    private let directoryURL: URL
    private let projectsURL: URL
    private let presetsURL: URL
    private let sidebarGroupsURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directoryURL = appSupport.appendingPathComponent("Laradeck", isDirectory: true)
        projectsURL = directoryURL.appendingPathComponent("projects.json")
        presetsURL = directoryURL.appendingPathComponent("presets.json")
        sidebarGroupsURL = directoryURL.appendingPathComponent("sidebarGroups.json")

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func loadProjects() -> [Project] {
        load([Project].self, from: projectsURL) ?? []
    }

    func saveProjects(_ projects: [Project]) {
        save(projects, to: projectsURL)
    }

    func loadPresets() -> [CommandPreset] {
        load([CommandPreset].self, from: presetsURL) ?? []
    }

    func savePresets(_ presets: [CommandPreset]) {
        save(presets, to: presetsURL)
    }

    func loadSidebarGroups() -> [SidebarGroup] {
        load([SidebarGroup].self, from: sidebarGroupsURL) ?? []
    }

    func saveSidebarGroups(_ groups: [SidebarGroup]) {
        save(groups, to: sidebarGroupsURL)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
