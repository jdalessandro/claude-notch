import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct PreferencesTests {
    func suite() -> UserDefaults {
        let name = "cn-test-\(UUID())"
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
    }

    @Test func roundTrips() {
        let d = suite(); var p = Preferences()
        p.islandStyle = .attached; p.panelWidth = .wide; p.notifyOnFinished = false; p.autoExpandSeconds = 12; p.costDisplay = .always
        p.save(d)
        #expect(Preferences.load(d) == p)
    }

    @Test func toleratesMissingUnknownAndInvalidValues() throws {
        let json = #"{"panelWidth":"gigantic","showPrompt":false,"futureSetting":{"a":1},"hoverDelay":"long","autoExpandSeconds":9999}"#
        let p = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(p.panelWidth == .regular)  // invalid enum -> default, not a decode failure
        #expect(p.showPrompt == false && p.hoverDelay == .long)
        #expect(p.autoExpandSeconds == 30)  // clamped
        #expect(p.soundEnabled == true)  // missing -> default
        #expect(Preferences.load(suite()) == Preferences())  // nothing stored -> defaults
    }

    @Test func expandedModeIsRememberedAndTolerant() throws {
        #expect(Preferences().expandedMode == .detailed)
        let d = suite(); var p = Preferences(); p.expandedMode = .compact; p.save(d)
        #expect(Preferences.load(d).expandedMode == .compact)  // survives "relaunch"
        let bad = try JSONDecoder().decode(Preferences.self, from: Data(#"{"expandedMode":"tiny"}"#.utf8))
        #expect(bad.expandedMode == .detailed)
    }

    @Test func corruptBlobFallsBackToDefaults() {
        let d = suite(); d.set(Data("not json".utf8), forKey: Preferences.defaultsKey)
        #expect(Preferences.load(d) == Preferences())
    }

    @Test func migratesLegacyKeysOnce() {
        let d = suite()
        d.set(false, forKey: "interactive"); d.set(false, forKey: "sound"); d.set("never", forKey: "costMode");
        d.set(false, forKey: "floatingIsland")
        let p = Preferences.load(d)
        #expect(!p.approveFromIsland && !p.soundEnabled && p.costDisplay == .never && p.islandStyle == .attached)
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
