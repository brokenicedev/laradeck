import XCTest
@testable import laradeck

final class GeneralServicesTests: XCTestCase {
    private let mailpit = """

    services:
      mailpit:
        image: axllent/mailpit
        container_name: mailpit-global
        ports:
          - "1025:1025"   # SMTP
          - "8025:8025"   # Web UI
        volumes:
          - mailpit-data:/data

    volumes:
      mailpit-data:
    """

    private let gotenberg = """
    services:
      gotenberg:
        image: gotenberg/gotenberg:8
        container_name: gotenberg-global
        ports:
          - "3000:3000"
    """

    func testFirstServiceNameSkipsTopLevelKeysAndBlankLines() {
        XCTAssertEqual(GeneralServicesManager.firstServiceName(in: mailpit), "mailpit")
        XCTAssertEqual(GeneralServicesManager.firstServiceName(in: gotenberg), "gotenberg")
        XCTAssertNil(GeneralServicesManager.firstServiceName(in: "volumes:\n  data:\n"))
    }

    func testFirstImageAndIcon() {
        XCTAssertEqual(GeneralServicesManager.firstImage(in: gotenberg), "gotenberg/gotenberg:8")
        let service = GeneralService(name: "mailpit", folderName: "laradeck-mailpit",
                                     image: GeneralServicesManager.firstImage(in: mailpit))
        XCTAssertEqual(service.systemImage, "envelope.fill")
    }

    func testServicesSavedBeforeAutoStartStillDecode() throws {
        let old = """
        [{"folderName":"laradeck-mailpit","id":"52FE6EC1-1EAB-492B-9E1C-B412C997BD3F",
          "image":"axllent/mailpit","name":"mailpit"}]
        """
        let services = try JSONDecoder().decode([GeneralService].self, from: Data(old.utf8))
        XCTAssertEqual(services.first?.name, "mailpit")
        XCTAssertEqual(services.first?.autoStart, false)

        var on = services[0]
        on.autoStart = true
        let roundTrip = try JSONDecoder().decode(GeneralService.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(roundTrip.autoStart)
    }
}
