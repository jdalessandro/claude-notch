import Foundation
import Testing

@testable import NotchbotCore

@Suite struct PreferencesTests {
    func suite() -> UserDefaults {
        let name = "cn-test-\(UUID())"
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
    }

    @Test func roundTrips() {
        let d = suite(); var p = Preferences()
        p.sessionRetention = .oneDay; p.notifyOnFinished = false; p.autoExpandOnEvents = false; p.costDisplay = .always
        p.save(d)
        #expect(Preferences.load(d) == p)
    }

    @Test func toleratesMissingUnknownAndInvalidValues() throws {
        // "panelWidth" is a setting from the old AppKit panel: old blobs must still load.
        let json = #"{"costDisplay":"gigantic","showPrompt":false,"futureSetting":{"a":1},"sessionRetention":"oneDay","panelWidth":"wide"}"#
        let p = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(p.costDisplay == .auto)  // invalid enum -> default, not a decode failure
        #expect(p.showPrompt == false && p.sessionRetention == .oneDay)
        #expect(p.soundEnabled == true)  // missing -> default
        #expect(Preferences.load(suite()) == Preferences())  // nothing stored -> defaults
    }

    @Test func corruptBlobFallsBackToDefaults() {
        let d = suite(); d.set(Data("not json".utf8), forKey: Preferences.defaultsKey)
        #expect(Preferences.load(d) == Preferences())
    }

    @Test func migratesLegacyKeysOnce() {
        let d = suite()
        d.set(false, forKey: "interactive"); d.set(false, forKey: "sound"); d.set("never", forKey: "costMode")
        let p = Preferences.load(d)
        #expect(!p.approveFromIsland && !p.soundEnabled && p.costDisplay == .never)
        p.save(d)
        d.set(true, forKey: "interactive")  // once saved, legacy keys are ignored
        #expect(Preferences.load(d).approveFromIsland == false)
    }

    @Test func notificationFiltering() {
        var p = Preferences(); p.notifyOnFinished = false
        #expect(p.shouldNotify(.permission) && p.shouldNotify(.input) && p.shouldNotify(.failed))
        #expect(!p.shouldNotify(.finished))
    }
}

@Suite struct IslandSizeTests {
    @Test func stepsAreOrderedAndDefaultIsOne() {
        let s = Preferences.IslandSize.allCases.map(\.scale)
        #expect(s == s.sorted() && Preferences().islandSize.scale == 1.0)
    }
    @Test func roundTripsAndInvalidFallsBack() throws {
        var p = Preferences(); p.islandSize = .larger
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        #expect(back.islandSize == .larger)
        let bad = try JSONDecoder().decode(Preferences.self, from: Data(#"{"islandSize":99}"#.utf8))
        #expect(bad.islandSize == .standard)
    }
}
