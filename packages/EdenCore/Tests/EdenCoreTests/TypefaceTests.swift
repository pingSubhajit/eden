@testable import EdenCore
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
}
