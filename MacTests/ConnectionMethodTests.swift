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

    // The receiver's cable came back as another interface (replugged, or
    // re-enumerated by the port): the dial scoped to the old one must move.
    func testPinFollowsTheCableToItsNewInterface() {
        let replugged = RouteInterface(name: "en8", isWiFi: false, isDirectLink: true)
        XCTAssertEqual(ConnectionMethod.cable.repin(from: "en4", among: [anri, replugged, wifi]), "en8")
        XCTAssertEqual(ConnectionMethod.wifi.repin(from: "en5", among: [cable, wifi]), "en0")
    }

    func testPinStaysWhileItStillReachesTheReceiver() {
        let second = RouteInterface(name: "en8", isWiFi: false, isDirectLink: true)
        // Browse order alone never moves a session.
        XCTAssertNil(ConnectionMethod.cable.repin(from: "en7", among: [second, cable, wifi]))
        XCTAssertNil(ConnectionMethod.cable.repin(from: "en7", among: [cable]))
        XCTAssertNil(ConnectionMethod.wifi.repin(from: "en0", among: [officeLAN, wifi]))
    }

    func testPinMovesUpFromAnriWhenTheRealCableAppears() {
        XCTAssertEqual(ConnectionMethod.cable.repin(from: "anri0", among: [anri, cable]), "en7")
        XCTAssertEqual(ConnectionMethod.wifi.repin(from: "en5", among: [officeLAN, wifi]), "en0")
    }

    func testPinStaysWhenTheMethodHasNowhereElseToGo() {
        // The record lost the cable entirely: withdrawal handling owns that.
        XCTAssertNil(ConnectionMethod.cable.repin(from: "en7", among: [wifi]))
        XCTAssertNil(ConnectionMethod.automatic.repin(from: "en7", among: [cable, wifi]))
    }

    func testCableTroubleNamesTheBlockingVPN() {
        let blocked = CableDialTrouble.hint(interface: "en8", tunnel: "utun8")
        XCTAssertTrue(blocked.contains("en8") && blocked.contains("utun8") && blocked.contains("VPN"))
        XCTAssertFalse(CableDialTrouble.hint(interface: "en8", tunnel: nil).contains("VPN"))
    }

    func testTunnelInterfacesAreRecognized() {
        XCTAssertTrue(CableDialTrouble.isTunnel("utun8"))
        XCTAssertTrue(CableDialTrouble.isTunnel("ipsec0"))
        XCTAssertTrue(CableDialTrouble.isTunnel("ppp0"))
        XCTAssertFalse(CableDialTrouble.isTunnel("en0"))
        XCTAssertFalse(CableDialTrouble.isTunnel("bridge0"))
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
