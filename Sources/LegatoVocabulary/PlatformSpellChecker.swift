import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// ``SpellChecking`` over the platform's checker: `UITextChecker` on iOS, `NSSpellChecker` on the Mac.
///
/// Both are main-actor types, so every call hops there.
public struct PlatformSpellChecker: SpellChecking {
    public init() {}

    /// Maps a bare code ("de", "en") to the closest entry of `available` (an exact match first, then the first
    /// "de_…" or "de-…" one), or returns `code` when nothing fits.
    static func resolve(_ code: String, available: [String]) -> String {
        if available.contains(code) { return code }
        let base = code.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? code
        if available.contains(base) { return base }
        let preferred = [base + "_" + base.uppercased()]
        for p in preferred where available.contains(p) { return p }
        return available.first { $0.hasPrefix(base + "_") || $0.hasPrefix(base + "-") } ?? code
    }

    #if canImport(UIKit)
    public func isKnown(_ word: String, language: String) async -> Bool {
        await MainActor.run {
            let ns = word as NSString
            guard ns.length > 0 else { return true }
            let checker = UITextChecker()
            let lang = Self.resolve(language, available: UITextChecker.availableLanguages)
            let r = checker.rangeOfMisspelledWord(
                in: word, range: NSRange(location: 0, length: ns.length), startingAt: 0, wrap: false, language: lang)
            return r.location == NSNotFound
        }
    }

    public func guesses(for word: String, language: String) async -> [String] {
        await MainActor.run {
            let ns = word as NSString
            guard ns.length > 0 else { return [] }
            let lang = Self.resolve(language, available: UITextChecker.availableLanguages)
            return UITextChecker().guesses(forWordRange: NSRange(location: 0, length: ns.length), in: word, language: lang) ?? []
        }
    }
    #elseif canImport(AppKit)
    public func isKnown(_ word: String, language: String) async -> Bool {
        await MainActor.run {
            let ns = word as NSString
            guard ns.length > 0 else { return true }
            let checker = NSSpellChecker.shared
            let lang = Self.resolve(language, available: checker.availableLanguages)
            let r = checker.checkSpelling(
                of: word, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            return r.location == NSNotFound
        }
    }

    public func guesses(for word: String, language: String) async -> [String] {
        await MainActor.run {
            let ns = word as NSString
            guard ns.length > 0 else { return [] }
            let checker = NSSpellChecker.shared
            let lang = Self.resolve(language, available: checker.availableLanguages)
            return checker.guesses(
                forWordRange: NSRange(location: 0, length: ns.length), in: word, language: lang,
                inSpellDocumentWithTag: 0) ?? []
        }
    }
    #else
    public func isKnown(_ word: String, language: String) async -> Bool { true }
    public func guesses(for word: String, language: String) async -> [String] { [] }
    #endif
}
