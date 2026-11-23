import BrainCore
import BrainHarness
import Foundation

/// The normalised form of a capture, plus everything pulled out of it.
///
/// **The original text is never modified.** Offsets in `Span` point into
/// `original`, so guard 2 (span grounding) still means something. A pipeline
/// that rewrites the text before parsing it has no way to prove where an
/// extracted value came from.
public struct NormalizedCapture: Sendable {
    /// Exactly as the user typed it.
    public let original: String
    /// NFC, collapsed whitespace, list numbering removed. Same character
    /// count semantics wherever possible, so offsets stay usable.
    public let normalized: String
    /// URLs lifted out, with their spans in `original`.
    public let urls: [(text: String, span: Span)]
    /// Safe to send to a model: phone numbers, emails, amounts and OTPs
    /// redacted (guard 10). Never stored, never shown to the user.
    public let redacted: String
    public let redactionApplied: Bool

    public var isEmpty: Bool {
        normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum Normalizer {

    /// T0. No model, no inference — Unicode and whitespace only.
    public static func normalize(_ text: String, stripPII: Bool = true) -> NormalizedCapture {
        let original = text
        // NFC first: combining marks must not split a word differently from
        // the same word typed precomposed.
        var working = text.precomposedStringWithCanonicalMapping

        // List numbering is formatting, not content. People number their dumps.
        if let match = DateParser.firstMatch(#"^\s*\d{1,3}[.)]\s+"#, working) {
            let span = DateParser.span(match)
            let utf16 = Array(working.utf16)
            working = String(decoding: utf16[span.end...], as: UTF16.self)
        }

        // Zero-width characters split words invisibly (adversarial adv-013).
        working = working.replacingOccurrences(
            of: "[\u{200B}\u{200C}\u{200D}\u{FEFF}]", with: "", options: .regularExpression)
        // Control characters, but not tab or newline, which are real structure.
        working = String(
            working.unicodeScalars.filter {
                !($0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t")
            })
        working = working.replacingOccurrences(
            of: "[ \t]+", with: " ", options: .regularExpression)
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)

        var urls: [(String, Span)] = []
        if let regex = try? NSRegularExpression(pattern: #"https?://\S+|\bwww\.\S+"#) {
            let range = NSRange(original.startIndex..., in: original)
            for match in regex.matches(in: original, range: range) {
                let span = Span(
                    start: match.range.location,
                    end: match.range.location + match.range.length)
                if let text = span.resolve(in: original) { urls.append((text, span)) }
            }
        }

        let (redacted, changed) = Guards.stripPII(working, enabled: stripPII)
        return NormalizedCapture(
            original: original, normalized: working, urls: urls,
            redacted: redacted, redactionApplied: changed)
    }
}
