import XCTest

final class FindMyPeopleRowsTests: XCTestCase {
    private let tabs = [
        FindMyPeopleRowsTests.line("People", x: 80, y: 65),
        FindMyPeopleRowsTests.line("Devices", x: 155, y: 65),
        FindMyPeopleRowsTests.line("Items", x: 230, y: 65),
    ]

    func testBuiltInPlaceAndReportedAge() {
        XCTAssertEqual(
            match(tabs + [Self.line("Test Person"), Self.line("Home • 4 min. ago", y: 121)]),
            ["status": "reported", "place": "Home", "lastSeen": "4 min. ago"]
        )
    }

    func testRawPlaceAndUnrecognizedAgeDoNotLeaveParser() {
        XCTAssertEqual(
            match(tabs + [Self.line("Test Person"), Self.line("456 Example St • Now", y: 121)]),
            ["status": "place_withheld", "lastSeen": "Now"]
        )
        XCTAssertNil(match(tabs + [Self.line("Test Person"), Self.line("Home • unknown status", y: 121)]))
    }

    func testCityAndRegionAreReportedWithNativeSeparator() {
        XCTAssertEqual(
            match(tabs + [Self.line("Test Person"), Self.line("Springfield, IL · 3 hr. ago", y: 121)]),
            ["status": "reported", "place": "Springfield, IL", "lastSeen": "3 hr. ago"]
        )
        XCTAssertEqual(
            match(tabs + [Self.line("Test Person"), Self.line("Example Street, IL · Now", y: 121)]),
            ["status": "place_withheld", "lastSeen": "Now"]
        )
    }

    func testUnavailableHasNoPlaceOrAge() {
        for detail in ["No Location Found", "Location Not Available"] {
            XCTAssertEqual(
                match(tabs + [Self.line("Test Person"), Self.line(detail, y: 121)]),
                ["status": "unavailable"]
            )
        }
    }

    func testPausedSharingWithholdsThePreviousPlaceAndAge() {
        for detail in ["Paused", "Springfield, IL • Paused", "Springfield, IL · Paused"] {
            XCTAssertEqual(
                match(tabs + [Self.line("Test Person"), Self.line(detail, y: 121)]),
                ["status": "paused"]
            )
        }
    }

    func testExpandedSelectedRowReturnsOnlyNearbyAndFreshness() {
        let row =
            tabs + [
                Self.line("Test Person"),
                Self.line("Nearby", y: 121),
                Self.line("456 Example St, Springfield", y: 138),
            ]
        XCTAssertEqual(
            match(row + [Self.line("Live", y: 155)]),
            ["status": "reported", "place": "Nearby", "lastSeen": "Live"]
        )
        XCTAssertEqual(
            match(row + [Self.line("Paused", y: 155)]),
            ["status": "paused"]
        )
        XCTAssertNil(match(row + [Self.line("Live", y: 189)]))
        XCTAssertNil(match(row + [Self.line("Live", x: 124, y: 155)]))
    }

    func testMissingSidebarPartialNameAndMapLabelAreRejected() {
        let detail = Self.line("Home • Now", y: 121)
        XCTAssertNil(match([Self.line("Test Person"), detail]))
        XCTAssertNil(match(tabs + [Self.line("Test Person Jr"), detail]))
        XCTAssertNil(match(tabs + [Self.line("Test Person", x: 470), detail]))
    }

    func testDuplicateAndMisalignedDetailAreRejected() {
        let name = Self.line("Test Person")
        let detail = Self.line("Home • Now", y: 121)
        XCTAssertNil(match(tabs + [name, detail, Self.line("Test Person", y: 170, confidence: 0.6)]))
        XCTAssertNil(match(tabs + [name, Self.line("Home • Now", x: 111, y: 121)]))
        XCTAssertNil(match(tabs + [name, Self.line("Home • Now", y: 121, confidence: 0.6)]))
        XCTAssertNil(match(tabs + [name, Self.line("Home • Now", y: 140)]))
    }

    private func match(_ lines: [FindMyPeopleRows.Line]) -> [String: String]? {
        FindMyPeopleRows.match(lines: lines, person: "Test Person")?.result
    }

    private static func line(
        _ text: String,
        x: CGFloat = 64,
        y: CGFloat = 104,
        confidence: Float = 0.98
    ) -> FindMyPeopleRows.Line {
        .init(text: text, bounds: .init(x: x, y: y, width: 56, height: 13), confidence: confidence)
    }
}
