import CoreText
@testable import EdenCore
import Foundation
import Testing

/// Astheric is found by its own name or not at all: a name CoreText doesn't
/// have never counts as installed, whatever font it hands back instead.
struct TypefaceTests {
    @Test func unknownFaceIsNotInstalled() {
        #expect(!Typeface.isInstalled("Eden-NoSuchFace-Regular"))
    }

    @Test func systemFaceIsInstalled() {
        // Helvetica is on every Mac and iPhone.
        #expect(Typeface.isInstalled("Helvetica"))
    }

    @Test func displayNameIsOneOfTheCandidatesAndInstalled() {
        guard let name = Typeface.displayName else { return }
        #expect(Typeface.candidates.contains(name))
        #expect(Typeface.isInstalled(name))
    }

    /// The copy the apps carry is the face they look for: a file swapped in
    /// brand/Fonts under another name would leave every heading in the
    /// fallback.
    @Test func bundledFaceIsACandidate() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../brand/\(Typeface.folder)", isDirectory: true)
            .standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let names = files.flatMap { file in
            (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? []).map {
                CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor($0, 12, nil)) as String
            }
        }
        #expect(names.contains(where: Typeface.candidates.contains))
    }

    /// The face comes from the app's own file, even on a Mac that has it
    /// installed too, so a heading looks the same everywhere.
    @Test func registeringAFolderDrawsFromItsFile() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../brand/\(Typeface.folder)", isDirectory: true)
            .standardizedFileURL
        Typeface.register(facesIn: folder)
        let name = try #require(Typeface.candidates.first(where: Typeface.isInstalled))
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let file = try #require(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        #expect(file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            == folder.resolvingSymlinksInPath())
    }

    @Test func registeringNothingIsHarmless() {
        Typeface.register(facesIn: nil)
        Typeface.register(facesIn: URL(fileURLWithPath: "/no/such/folder"))
    }
}
