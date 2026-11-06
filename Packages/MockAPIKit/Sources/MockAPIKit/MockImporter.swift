import Foundation
import HTTPKit

public enum MockImportFormat: String, Sendable {
    case openAPI3 = "OpenAPI 3"
    case swagger2 = "Swagger 2"
    case postman = "Postman collection"
    case laradeck = "Laradeck mock"
}

public struct MockImportResult: Sendable {
    public var server: MockServer
    public var format: MockImportFormat
    public var warnings: [String]
}

/// Detects the file type and builds a `MockServer` from it.
public enum MockImporter {
    public static func importData(_ data: Data, fileName: String? = nil, port: Int = 3001) throws -> MockImportResult {
        let root = try SpecLoader.parse(data)
        var result: MockImportResult

        if OpenAPIImporter.canImport(root) {
            var importer = OpenAPIImporter(root: root)
            let server = try importer.makeServer(port: port)
            result = MockImportResult(server: server, format: importer.isSwagger2 ? .swagger2 : .openAPI3, warnings: importer.warnings)
        } else if PostmanImporter.canImport(root) {
            var importer = PostmanImporter(root: root)
            let server = try importer.makeServer(port: port)
            result = MockImportResult(server: server, format: .postman, warnings: importer.warnings)
        } else if root["routes"]?.array != nil, root["port"] != nil {
            do {
                var server = try JSONDecoder().decode(MockServer.self, from: Data(root.serialized().utf8))
                // A fresh identity, so importing twice doesn't clash.
                server.id = UUID()
                result = MockImportResult(server: server, format: .laradeck, warnings: [])
            } catch {
                throw MockImportError.invalid("The Laradeck mock file is damaged: \(error.localizedDescription)")
            }
        } else {
            throw MockImportError.unknownFormat
        }

        result.server.source = fileName
        if result.format != .laradeck { result.server.port = port }
        return result
    }

    public static func importFile(at url: URL, port: Int = 3001) throws -> MockImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MockImportError.unreadable(error.localizedDescription)
        }
        return try importData(data, fileName: url.lastPathComponent, port: port)
    }

    /// The Laradeck mock format: the server as pretty JSON.
    public static func export(_ server: MockServer) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(server)
    }
}
