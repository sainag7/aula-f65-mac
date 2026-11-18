import XCTest
@testable import F65Kit

final class LooksTests: XCTestCase {
    func block() throws -> LightingBlock { try LightingBlock(MockTransport().read(0x44)) }

    func testKeyboardLookWritesOnlyItsEffectSlotAndSideLights() throws {
        let before = try block()
        var look = Look.keyboard("t", "Test", effect: 16, brightness: 3, speed: 1, colour: 2, side: [3, 4, 2, 1])
        let after = try look.applied(to: before)
        XCTAssertEqual(after.effect, 16)
        XCTAssertEqual([after.brightness(16), after.speed(16), after.colour(16)], [3, 1, 2])
        XCTAssertEqual(["sideEffect", "sideColour", "sideBrightness", "sideSpeed"].map(after.side), [3, 4, 2, 1])
        for e in 1...18 where e != 16 {
            XCTAssertEqual([after.brightness(e), after.speed(e), after.colour(e)], [before.brightness(e), before.speed(e), before.colour(e)])
        }
        XCTAssertTrue(look.matches(after))
        look.side = nil
        XCTAssertTrue(look.matches(after))
        XCTAssertEqual(Look.capture(after).effect, 16)
        XCTAssertTrue(Look.capture(after).matches(after))
        XCTAssertThrowsError(try Look.app("a", "A", background: "dark", keyColors: [:]).applied(to: before))
    }

    func testAppLookLiveSettingsRoundTrip() {
        let red = RGB(r: 255, g: 0, b: 0)
        let look = Look.app("w", "WASD", background: "effect:16", keyColors: ["w": red, "nope": red], brightness: 0.5)
        let s = look.liveSettings(Settings())
        XCTAssertEqual(s.mode, .effect); XCTAssertEqual(s.effect, 16); XCTAssertEqual(s.brightness, 0.5)
        XCTAssertEqual(s.keyColors, ["w": red]); XCTAssertFalse(s.paused)
        XCTAssertEqual(Look.fromLive(s, name: "x").background, "effect:16")
        // A reactive background can't be drawn: falls back to dark.
        XCTAssertEqual(Look.app("r", "R", background: "effect:7", keyColors: [:]).liveSettings(Settings()).mode, .dark)
        // Keyboard looks stop the stream so saved lighting shows.
        XCTAssertEqual(Look.keyboard("k", "K", effect: 1).liveSettings(s).mode, .off)
    }

    func testPreviewFramesHaveEveryKeyAndRespectBrightness() {
        let pal = Palette.factory
        let dark = Look.keyboard("d", "D", effect: 1, brightness: 0, colour: 0).previewFrame(time: 1, palette: pal)
        XCTAssertEqual(dark.count, KeyMap.slotCount); XCTAssertTrue(dark.allSatisfy(\.isBlack))
        let red = Look.keyboard("r", "R", effect: 1, brightness: 4, colour: 0).previewFrame(time: 1, palette: pal)
        XCTAssertEqual(red[PhysicalKey.slots["q"]!], RGB(r: 255, g: 0, b: 0))
        let wasd = LookStore.starters.first { $0.id == "wasd" }!.previewFrame(time: 2, palette: pal)
        XCTAssertEqual(wasd[PhysicalKey.slots["w"]!], RGB(r: 255, g: 30, b: 30))
    }

    func testStoreSavesFavouritesAndUniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("looks.json")
        let store = LookStore(url: url)
        XCTAssertEqual(store.looks.count, LookStore.starters.count)
        let added = store.add(Look.app("x", "Waterfall", background: "wave", keyColors: ["q": RGB(r: 1, g: 2, b: 3)]))
        XCTAssertEqual(added.name, "Waterfall 2"); XCTAssertFalse(added.builtIn)
        store.toggleFavourite(added.id)
        let reloaded = LookStore(url: url)
        XCTAssertEqual(reloaded.look(added.id)?.keyColors, ["q": RGB(r: 1, g: 2, b: 3)])
        XCTAssertEqual(reloaded.look(added.id)?.favourite, true)
        let favs = reloaded.favourites.map(\.id)
        XCTAssertEqual(reloaded.nextFavourite(after: favs.last)?.id, favs.first)
        XCTAssertEqual(reloaded.nextFavourite(after: nil)?.id, favs.first)
        reloaded.remove(added.id); XCTAssertNil(LookStore(url: url).look(added.id))
        try? FileManager.default.removeItem(at: dir)
    }

    func testCorruptLookFileFallsBackAndBadFieldsAreClamped() throws {
        let json = ##"[{"id":"a","name":"A","kind":"keyboard","effect":40,"brightness":9,"colour":-2},{"id":"b","kind":"app","keyColors":{"w":"#ff0000","zz":"#00ff00","a":"nothex"}}]"##
        let looks = try JSONDecoder().decode([Look].self, from: Data(json.utf8))
        XCTAssertEqual([looks[0].effect, looks[0].brightness, looks[0].colour], [18, 4, 0])
        XCTAssertEqual(looks[1].keyColors, ["w": RGB(r: 255, g: 0, b: 0)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("looks.json"); try Data("not json".utf8).write(to: url)
        XCTAssertEqual(LookStore(url: url).looks.count, LookStore.starters.count)
        try? FileManager.default.removeItem(at: dir)
    }

    func testCommandParser() {
        let looks = LookStore.starters, pal = Palette.factory
        func first(_ q: String, kb: Bool = true) -> LookCommand? { CommandParser.suggestions(q, looks: looks, keyboardLook: kb, palette: pal).first?.command }
        XCTAssertEqual(first("wasd red"), .paint(["w", "a", "s", "d"], RGB(r: 255, g: 0, b: 0)))
        XCTAssertEqual(first("esc enter cyan"), .paint(["esc", "enter"], RGB(r: 0, g: 255, b: 255)))
        XCTAssertEqual(first("home row amber"), .paint(KeyRegions.ids("Home row")!, RGB(r: 255, g: 170, b: 50)))
        XCTAssertEqual(first("dim 50"), .brightness(50))
        XCTAssertEqual(CommandParser.suggestions("dim 50", looks: looks, keyboardLook: true, palette: pal).first?.detail, "keyboard step 2 of 4")
        XCTAssertEqual(first("off"), .lightsOff)
        XCTAssertEqual(first("undo"), .undo)
        XCTAssertEqual(first("storm"), .apply("storm"))
        XCTAssertEqual(first("neon"), .effect(11))
        XCTAssertEqual(first("orange"), .colour(RGB(r: 255, g: 100, b: 0)))
        XCTAssertTrue(CommandParser.suggestions("orange", looks: looks, keyboardLook: true, palette: pal)[0].detail.contains("pick a slot"))
        XCTAssertEqual(CommandParser.suggestions("red", looks: looks, keyboardLook: true, palette: pal)[0].detail, "keyboard colour 1")
        XCTAssertTrue(CommandParser.suggestions("", looks: looks, keyboardLook: true, palette: pal).isEmpty)
        XCTAssertTrue(CommandParser.suggestions("qqqq", looks: looks, keyboardLook: true, palette: pal).isEmpty)
    }

    func testColourSlotHelpersRegionsAndBudget() throws {
        var b = try block()
        for e in 1...18 { try b.setSlot(e, brightness: 4, speed: 2, colour: 7) }
        try b.setSlot(2, brightness: 4, speed: 2, colour: 5); try b.setSlot(3, brightness: 4, speed: 2, colour: 5); try b.setSlot(8, brightness: 4, speed: 2, colour: 6)
        XCTAssertEqual(b.effects(usingColour: 5), [2, 3])
        XCTAssertEqual(b.leastUsedColourSlot(keeping: nil), 4)
        XCTAssertEqual(b.leastUsedColourSlot(keeping: 4), 3)
        XCTAssertEqual(Palette.nearestSlot(to: RGB(r: 250, g: 120, b: 0), in: Palette.factory), 0)
        XCTAssertEqual(KeyRegions.ids("wasd"), ["w", "a", "s", "d"])
        XCTAssertEqual(Set(KeyRegions.ids("All")!), Set(PhysicalKey.ids))
        let red = RGB(r: 255, g: 0, b: 0), blue = RGB(r: 0, g: 0, b: 255)
        XCTAssertEqual(LiveBudget.pinnedBytes(["w": red, "a": red, "s": blue, "x": .black]), (4 + 2) + (4 + 1))
        XCTAssertEqual(LiveBudget.frameBytes, 168)
    }

    func testRestorePointDateAndLighting() throws {
        let store = BackupStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let url = try store.write(try Snapshot(MockTransport()))
        XCTAssertLessThan(abs(BackupStore.date(of: url)!.timeIntervalSinceNow), 5)
        XCTAssertEqual(store.lighting(in: url)?.bytes.count, 128)
        try? FileManager.default.removeItem(at: store.directory)
    }

    func testKeyGeometryWidths() {
        XCTAssertEqual(KeyGeometry.keys.first { $0.id == "space" }?.width, 6.25)
        XCTAssertEqual(KeyGeometry.keys.first { $0.id == "left" }?.x, 13.0)
    }
}
