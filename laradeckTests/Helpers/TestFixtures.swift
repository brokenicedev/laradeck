import Foundation

enum TestFixtures {
    static var laravelMinimal: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/laravel-minimal")
    }
}
