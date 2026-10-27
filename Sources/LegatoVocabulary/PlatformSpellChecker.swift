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

    /// One hop to the main actor for the whole batch, with one checker reused for every word.
    public func knownLanguages(for words: [String], languages: [String]) async -> [String: Set<String>] {
        await MainActor.run {
            let checker = UITextChecker()
            let available = UITextChecker.availableLanguages
            let resolved = languages.map { (code: $0, language: Self.resolve($0, available: available)) }
            var out: [String: Set<String>] = [:]
            for word in words where out[word] == nil {
                let ns = word as NSString
                var known = Set<String>()
                for (code, language) in resolved {
                    let missing = ns.length > 0 && checker.rangeOfMisspelledWord(
                        in: word, range: NSRange(location: 0, length: ns.length), startingAt: 0, wrap: false,
                        language: language).location != NSNotFound
                    if !missing { known.insert(code) }
                }
                out[word] = known
            }
            return out
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

    /// One hop to the main actor for the whole batch.
    public func knownLanguages(for words: [String], languages: [String]) async -> [String: Set<String>] {
        await MainActor.run {
            let checker = NSSpellChecker.shared
            let available = checker.availableLanguages
            let resolved = languages.map { (code: $0, language: Self.resolve($0, available: available)) }
            var out: [String: Set<String>] = [:]
            for word in words where out[word] == nil {
                let ns = word as NSString
                var known = Set<String>()
                for (code, language) in resolved {
                    let missing = ns.length > 0 && checker.checkSpelling(
                        of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
                    ).location != NSNotFound
                    if !missing { known.insert(code) }
                }
                out[word] = known
            }
            return out
        }
    }
    #else
    public func isKnown(_ word: String, language: String) async -> Bool { true }
    public func guesses(for word: String, language: String) async -> [String] { [] }
    #endif
}

// MARK: completions

extension PlatformSpellChecker: WordCompleting {
    /// Round-robin over the per-language lists, dropping repeats (case-insensitively), so the first language
    /// does not crowd out the others.
    static func interleave(_ lists: [[String]]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count && seen.insert(list[i].lowercased()).inserted { out.append(list[i]) }
        }
        return out
    }

    /// The most completions asked of one language.
    static let completionsPerLanguage = 6

    #if canImport(UIKit)
    public func completions(prefix: String, languages: [String]) async -> [String] {
        await MainActor.run {
            let ns = prefix as NSString
            guard ns.length > 0 else { return [] }
            let checker = UITextChecker()
            let available = UITextChecker.availableLanguages
            return Self.interleave(languages.map { code in
                let found = checker.completions(
                    forPartialWordRange: NSRange(location: 0, length: ns.length), in: prefix,
                    language: Self.resolve(code, available: available)) ?? []
                return Array(found.prefix(Self.completionsPerLanguage))
            })
        }
    }
    #elseif canImport(AppKit)
    public func completions(prefix: String, languages: [String]) async -> [String] {
        await MainActor.run {
            let ns = prefix as NSString
            guard ns.length > 0 else { return [] }
            let checker = NSSpellChecker.shared
            let available = checker.availableLanguages
            return Self.interleave(languages.map { code in
                let found = checker.completions(
                    forPartialWordRange: NSRange(location: 0, length: ns.length), in: prefix,
                    language: Self.resolve(code, available: available), inSpellDocumentWithTag: 0) ?? []
                return Array(found.prefix(Self.completionsPerLanguage))
            })
        }
    }
    #else
    public func completions(prefix: String, languages: [String]) async -> [String] { [] }
    #endif
}
