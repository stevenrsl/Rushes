import Foundation
import Testing
@testable import Rushes

// Settings saved by an older Rushes hold the defaults of their own day. A
// default that changes has to reach them, once, without walking over an
// answer given since.

@Suite("Settings")
struct SettingsTests {
    private func defaults(_ json: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "rushes-tests-\(UUID().uuidString)")!
        suite.set(Data(json.utf8), forKey: IngestSettings.storageKey)
        return suite
    }

    @Test("settings written before migrations existed take the new default")
    func oldSettingsAreBroughtUp() {
        // What was on disk on 2026-09-21: no schema, skipping off.
        let suite = defaults(#"{"initials":"SR","client":"Kaffi","skipAlreadyCopied":false}"#)
        let settings = IngestSettings.load(from: suite)

        #expect(settings.skipAlreadyCopied)
        #expect(settings.schema == IngestSettings.schema)
        // The rest is left exactly as it was.
        #expect(settings.initials == "SR")
        #expect(settings.client == "Kaffi")
    }

    @Test("the migration runs once, and a choice made afterwards stands")
    func aLaterChoiceIsKept() {
        let suite = defaults(#"{"skipAlreadyCopied":false}"#)
        #expect(IngestSettings.load(from: suite).skipAlreadyCopied)

        // Unticked by hand after the migration, and saved.
        var settings = IngestSettings.load(from: suite)
        settings.skipAlreadyCopied = false
        settings.save(to: suite)

        #expect(!IngestSettings.load(from: suite).skipAlreadyCopied)
        #expect(!IngestSettings.load(from: suite).skipAlreadyCopied)
    }

    @Test("a migration is written back, so it does not depend on being saved later")
    func migrationIsPersisted() throws {
        let suite = defaults(#"{"skipAlreadyCopied":false}"#)
        _ = IngestSettings.load(from: suite)

        let data = try #require(suite.data(forKey: IngestSettings.storageKey))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["skipAlreadyCopied"] as? Bool == true)
        #expect(json["schema"] as? Int == IngestSettings.schema)
    }

    @Test("nothing saved at all is the current defaults")
    func emptyIsDefault() {
        let suite = UserDefaults(suiteName: "rushes-tests-\(UUID().uuidString)")!
        let settings = IngestSettings.load(from: suite)
        #expect(settings == IngestSettings())
        #expect(settings.skipAlreadyCopied)
    }

    @Test("ejecting, saved as a switch before 2026-10-15, is still read")
    func legacyEject() {
        #expect(IngestSettings.load(from: defaults(#"{"ejectWhenDone":false}"#)).whenDone == .keep)
        #expect(IngestSettings.load(from: defaults(#"{"ejectWhenDone":true}"#)).whenDone == .eject)
        #expect(IngestSettings.load(from: defaults(#"{}"#)).whenDone == .eject)
        #expect(IngestSettings.load(from: defaults(#"{"whenDone":"offerFormat","ejectWhenDone":true}"#)).whenDone == .offerFormat)
    }

    @Test("the ambiance and the send are kept, and default to the forest and nothing")
    func ambianceAndUpload() {
        var settings = IngestSettings()
        #expect(settings.ambiance == .forest)
        #expect(settings.titles == .serif)
        #expect(settings.upload.kind == .none)
        #expect(!settings.uploadWhenDone)

        let suite = UserDefaults(suiteName: "rushes-tests-\(UUID().uuidString)")!
        settings.ambiance = .lavender
        settings.titles = .sans
        settings.upload.kind = .ftps
        settings.upload.host = "nas.local"
        settings.save(to: suite)
        let loaded = IngestSettings.load(from: suite)
        #expect(loaded.ambiance == .lavender)
        #expect(loaded.titles == .sans)
        #expect(loaded.upload.kind == .ftps)
        #expect(loaded.upload.host == "nas.local")
    }

    @Test("the folder layout saved as a name is still read")
    func legacyLayoutName() {
        let suite = defaults(#"{"layout":"byType"}"#)
        #expect(IngestSettings.load(from: suite).layout == FolderLayout.byType)
    }
}
