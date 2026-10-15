import XCTest

final class ConnectionMethodTests: XCTestCase {
    // A Mac receiver seen over WiFi and a USB-C host-to-host cable, plus the
    // Apple-internal anri link that comes up next to that cable.
    private let wifi = RouteInterface(name: "en0", isWiFi: true, isDirectLink: false)
    private let cable = RouteInterface(name: "en7", isWiFi: false, isDirectLink: true)
    private let anri = RouteInterface(name: "anri0", isWiFi: false, isDirectLink: true)
    private let officeLAN = RouteInterface(name: "en5", isWiFi: false, isDirectLink: false)

    func testAutomaticLeavesThePathToTheSystem() {
        XCTAssertEqual(ConnectionMethod.automatic.route(among: [anri, cable, wifi]), .anyPath)
        XCTAssertEqual(ConnectionMethod.automatic.route(among: []), .anyPath)
    }

    func testCablePinsTheDirectLinkEvenWhenWiFiIsListedFirst() {
        XCTAssertEqual(ConnectionMethod.cable.route(among: [wifi, cable]), .pinned("en7"))
    }

    func testCablePrefersTheRealLinkOverAnri() {
        XCTAssertEqual(ConnectionMethod.cable.route(among: [anri, cable, wifi]), .pinned("en7"))
        XCTAssertEqual(ConnectionMethod.cable.route(among: [anri, wifi]), .pinned("anri0"))
    }

    func testCableWithoutACableIsUnavailableNotWiFi() {
        XCTAssertEqual(ConnectionMethod.cable.route(among: [wifi]), .unavailable)
        // A routed wired LAN is not the cable either.
        XCTAssertEqual(ConnectionMethod.cable.route(among: [officeLAN, wifi]), .unavailable)
        XCTAssertEqual(ConnectionMethod.cable.route(among: []), .unavailable)
    }

    func testWiFiPinsWiFiAndNeverTheCable() {
        XCTAssertEqual(ConnectionMethod.wifi.route(among: [cable, anri, wifi]), .pinned("en0"))
        XCTAssertEqual(ConnectionMethod.wifi.route(among: [cable, anri]), .unavailable)
    }

    func testWiFiFallsBackToAnotherNetworkPath() {
        XCTAssertEqual(ConnectionMethod.wifi.route(among: [cable, officeLAN]), .pinned("en5"))
        XCTAssertEqual(ConnectionMethod.wifi.route(among: [officeLAN, wifi]), .pinned("en0"))
    }

    func testOnlyAutomaticSwitchesPathsOnItsOwn() {
        XCTAssertTrue(ConnectionMethod.automatic.switchesPathsOnItsOwn)
        XCTAssertFalse(ConnectionMethod.cable.switchesPathsOnItsOwn)
        XCTAssertFalse(ConnectionMethod.wifi.switchesPathsOnItsOwn)
    }

    func testUSBAndCablePlugFollowTheMethod() {
        XCTAssertTrue(ConnectionMethod.automatic.allowsUSB)
        XCTAssertTrue(ConnectionMethod.cable.allowsUSB)
        XCTAssertFalse(ConnectionMethod.wifi.allowsUSB)
        XCTAssertTrue(ConnectionMethod.automatic.connectsOnCablePlug)
        XCTAssertTrue(ConnectionMethod.cable.connectsOnCablePlug)
        XCTAssertFalse(ConnectionMethod.wifi.connectsOnCablePlug)
    }

    func testConnectPicksUSBFirstUnlessWiFiIsChosen() {
        let both = (target: "wifi", route: ServiceRoute.pinned("en0"))
        XCTAssertEqual(ConnectionMethod.automatic.pick(usb: "usb", network: (target: "wifi", route: .anyPath)), "usb")
        XCTAssertEqual(ConnectionMethod.cable.pick(usb: "usb", network: both), "usb")
        XCTAssertEqual(ConnectionMethod.wifi.pick(usb: "usb", network: both), "wifi")
    }

    func testConnectOffersNothingWhenEveryPathIsRuledOut() {
        let wifiOnly = (target: "wifi", route: ServiceRoute.unavailable)
        XCTAssertNil(ConnectionMethod.cable.pick(usb: nil, network: wifiOnly))
        XCTAssertNil(ConnectionMethod.wifi.pick(usb: "usb", network: nil))
        XCTAssertEqual(ConnectionMethod.cable.pick(usb: nil, network: (target: "mac", route: .pinned("en7"))), "mac")
    }

    func testChoiceIsPersistedAndDefaultsToAutomatic() {
        let defaults = UserDefaults(suiteName: "ConnectionMethodTests")!
        defaults.removePersistentDomain(forName: "ConnectionMethodTests")
        XCTAssertEqual(ConnectionMethod.load(from: defaults), .automatic)
        defaults.set("cable", forKey: ConnectionMethod.defaultsKey)
        XCTAssertEqual(ConnectionMethod.load(from: defaults), .cable)
        defaults.set("bogus", forKey: ConnectionMethod.defaultsKey)
        XCTAssertEqual(ConnectionMethod.load(from: defaults), .automatic)
        defaults.removePersistentDomain(forName: "ConnectionMethodTests")
    }
}
