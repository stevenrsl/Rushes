import Foundation
import Testing
@testable import Rushes

// A for the A7 IV, D for the drone, every night without typing it.

@Suite("Camera letters")
struct CameraTests {
    let a7 = KnownCamera(id: "Sony ILCE-7M4 #5012345", name: "Sony ILCE-7M4", label: "A")
    let drone = KnownCamera(id: "DJI", name: "DJI", label: "D")

    @Test("a known camera gets its letter back")
    func knownLetter() {
        #expect(CameraLetters.letter(for: "DJI", known: [a7, drone], taken: []) == "D")
        #expect(CameraLetters.letter(for: a7.id, known: [a7, drone], taken: ["B"]) == "A")
    }

    @Test("a new camera never borrows a letter another camera holds")
    func newCamera() {
        #expect(CameraLetters.letter(for: "Canon EOS R5", known: [a7, drone], taken: []) == "B")
        #expect(CameraLetters.letter(for: nil, known: [a7, drone], taken: ["B"]) == "C")
    }

    @Test("two bodies the camera cannot tell apart do not share a letter")
    func sameLetterTaken() {
        #expect(CameraLetters.letter(for: "DJI", known: [drone], taken: ["D"]) == "A")
    }

    @Test("remembering replaces the camera's old letter")
    func remembering() {
        let camera = CameraIdentity(name: "DJI", serial: nil)
        let list = CameraLetters.remembering(camera, label: "DR", in: [a7, drone])
        #expect(list.count == 2)
        #expect(list.first { $0.id == "DJI" }?.label == "DR")
    }

    @Test("the serial makes two bodies of one model two cameras")
    func serial() {
        #expect(CameraIdentity(name: "Sony ILCE-7M4", serial: "123").id != CameraIdentity(name: "Sony ILCE-7M4", serial: "456").id)
        #expect(CameraIdentity(name: "DJI", serial: nil).id == "DJI")
    }

    @Test("Sony's clip XML names the body")
    func sonyXML() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
          <Duration value="1234"/>
          <Device manufacturer="Sony" modelName="ILME-FX3" serialNo="4712345"/>
        </NonRealTimeMeta>
        """
        let device = CameraLetters.device(inSonyXML: xml)
        #expect(device?.name == "Sony ILME-FX3")
        #expect(device?.serial == "4712345")
        #expect(CameraLetters.device(inSonyXML: "<NonRealTimeMeta/>") == nil)
    }

    @Test("letters survive a round trip through the settings")
    func settings() throws {
        var s = IngestSettings()
        s.cameras = [a7, drone]
        let decoded = try JSONDecoder().decode(IngestSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.cameras == [a7, drone])
        let old = try JSONDecoder().decode(IngestSettings.self, from: Data(#"{"initials":"SR"}"#.utf8))
        #expect(old.cameras.isEmpty)
        #expect(old.initials == "SR")
    }
}
