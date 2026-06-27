// ContentAnalysis.swift
// LumaClip — macOS Clipboard Manager
//
// On-capture analysis + post-capture transform utilities bundled
// together because they all operate on a clip's content without any
// cross-file dependencies:
//   • ContentHasher       — SHA-256 for exact-duplicate dedup
//   • SensitivityDetector — regex + Luhn for credit cards / tokens / keys
//   • OCRService          — Vision-based text recognition from images
//   • PasteTransform      — deterministic content transforms (case, JSON,
//                            base64, url encode, colour, lines, …)
//   • QRCodeGenerator     — on-device QR image from any string
// All local, no network, no API.

import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Vision

// MARK: - Content Hasher

enum ContentHasher {
    /// SHA-256 of normalized content. Whitespace at both ends is trimmed
    /// and interior whitespace sequences collapse to a single space, so
    /// trivially-different clips (trailing newline added by some apps)
    /// still collide for dedup purposes. Empty/whitespace-only content
    /// returns an empty hash — callers should skip inserting in that case.
    static func hash(_ content: String) -> String {
        let normalized = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
        if normalized.isEmpty { return "" }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hash for image blobs — plain SHA-256 of the JPEG bytes. Good
    /// enough for exact-dup detection (same screenshot pasted twice).
    static func hash(imageData: Data) -> String {
        let digest = SHA256.hash(data: imageData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Sensitivity Detector

enum SensitivityDetector {
    /// Returns true when content looks like a credit card, JWT, API key,
    /// AWS/Stripe/GitHub secret, or similar. Conservative — false positives
    /// are worse than missing the occasional short token, because the user
    /// sees a shield badge and may opt into burn-after-paste.
    static func detect(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12, trimmed.count <= 4096 else { return false }

        // JWT: three base64url segments separated by dots.
        if matches(trimmed, pattern: #"^ey[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$"#) {
            return true
        }

        // Vendor-prefixed API keys (Stripe, GitHub, Slack, OpenAI, AWS, …).
        let vendorPrefixes = [
            #"^sk_(live|test)_[A-Za-z0-9]{16,}$"#,                 // Stripe secret
            #"^pk_(live|test)_[A-Za-z0-9]{16,}$"#,                 // Stripe publishable
            #"^rk_(live|test)_[A-Za-z0-9]{16,}$"#,                 // Stripe restricted
            #"^gh[pousr]_[A-Za-z0-9]{20,}$"#,                      // GitHub tokens
            #"^xox[aboprs]-[A-Za-z0-9-]{10,}$"#,                   // Slack tokens
            #"^sk-[A-Za-z0-9]{20,}$"#,                             // OpenAI-style
            #"^AKIA[0-9A-Z]{16}$"#,                                // AWS access key
            #"^ASIA[0-9A-Z]{16}$"#,                                // AWS temp
            #"^AIza[0-9A-Za-z_\-]{30,}$"#,                         // Google API key
        ]
        for pattern in vendorPrefixes where matches(trimmed, pattern: pattern) {
            return true
        }

        // Credit card: 13–19 digits with optional separators, Luhn-valid.
        if looksLikeCreditCard(trimmed) {
            return true
        }

        // Generic high-entropy long hex / base64 strings that look like
        // secrets (64+ chars, no spaces, mixed classes). Deliberately
        // narrow: normal IDs and git SHAs (40 hex) don't match.
        if trimmed.count >= 64,
           !trimmed.contains(" "),
           matches(trimmed, pattern: #"^[A-Za-z0-9+/=_\-]{64,}$"#),
           hasMixedClasses(trimmed) {
            return true
        }

        return false
    }

    // MARK: private

    /// Card-shaped digit run passes the Luhn checksum.
    private static func looksLikeCreditCard(_ text: String) -> Bool {
        let digitsOnly = text.filter(\.isWholeNumber)
        guard (13...19).contains(digitsOnly.count) else { return false }
        // Allow digits + spaces + dashes only — not arbitrary text with
        // a long digit run inside it.
        let allowedOnly = text.allSatisfy { $0.isWholeNumber || $0 == " " || $0 == "-" }
        guard allowedOnly else { return false }
        return luhnValid(digitsOnly)
    }

    /// Standard Luhn mod-10. Right-to-left, double every second digit.
    private static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var alt = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            var add = d
            if alt {
                add *= 2
                if add > 9 { add -= 9 }
            }
            sum += add
            alt.toggle()
        }
        return sum % 10 == 0
    }

    private static func hasMixedClasses(_ text: String) -> Bool {
        let hasUpper = text.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasLower = text.range(of: "[a-z]", options: .regularExpression) != nil
        let hasDigit = text.range(of: "[0-9]", options: .regularExpression) != nil
        let count = [hasUpper, hasLower, hasDigit].filter { $0 }.count
        return count >= 2
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - OCR Service

enum OCRService {
    /// Run VNRecognizeTextRequest on an NSImage. Completion fires on a
    /// background queue — caller is responsible for hopping back to the
    /// main queue if touching UI. On failure (unsupported image, Vision
    /// error) the completion receives an empty string.
    ///
    /// Kept async because recognition can take 100–500 ms for real
    /// screenshots; blocking the clipboard poll timer would stall the
    /// whole capture loop.
    static func recognizeText(
        in image: NSImage,
        completion: @escaping (String) -> Void
    ) {
        guard let cgImage = cgImage(from: image) else {
            completion("")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    completion("")
                    return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                completion(lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("[OCRService] Vision error: \(error.localizedDescription)")
                completion("")
            }
        }
    }

    /// NSImage → CGImage bridge that survives images backed by either
    /// a bitmap rep or arbitrary representations (Vision only accepts CG).
    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

// MARK: - Paste Transforms

/// Deterministic content transformations. Each case represents a single
/// reversible-ish conversion the user can invoke from the clip's context
/// menu. No AI, no network — just string manipulation.
///
/// Grouped by category so the context menu can render them inside nested
/// submenus instead of a giant flat list.
enum PasteTransform: String, CaseIterable, Identifiable {
    // Case
    case upperCase, lowerCase, titleCase
    case snakeCase, camelCase, kebabCase

    // Whitespace
    case trimWhitespace, collapseWhitespace

    // Encoding
    case urlEncode, urlDecode
    case base64Encode, base64Decode
    case escapeHTML, unescapeHTML

    // JSON
    case jsonPretty, jsonMinify

    // Lines
    case linesSort, linesDedup, linesReverse

    // Colour
    case hexToRGB, rgbToHex

    var id: String { rawValue }

    /// Display label for the menu row.
    var label: String {
        switch self {
        case .upperCase:         return "UPPERCASE"
        case .lowerCase:         return "lowercase"
        case .titleCase:         return "Title Case"
        case .snakeCase:         return "snake_case"
        case .camelCase:         return "camelCase"
        case .kebabCase:         return "kebab-case"
        case .trimWhitespace:    return "Trim Whitespace"
        case .collapseWhitespace:return "Collapse Whitespace"
        case .urlEncode:         return "URL Encode"
        case .urlDecode:         return "URL Decode"
        case .base64Encode:      return "Base64 Encode"
        case .base64Decode:      return "Base64 Decode"
        case .escapeHTML:        return "Escape HTML"
        case .unescapeHTML:      return "Unescape HTML"
        case .jsonPretty:        return "JSON · Pretty Print"
        case .jsonMinify:        return "JSON · Minify"
        case .linesSort:         return "Lines · Sort"
        case .linesDedup:        return "Lines · Dedup"
        case .linesReverse:      return "Lines · Reverse"
        case .hexToRGB:          return "Hex → RGB"
        case .rgbToHex:          return "RGB → Hex"
        }
    }

    /// SF Symbol for the menu row.
    var icon: String {
        switch self {
        case .upperCase, .lowerCase, .titleCase,
             .snakeCase, .camelCase, .kebabCase:    return "textformat"
        case .trimWhitespace, .collapseWhitespace: return "arrow.left.and.right"
        case .urlEncode, .urlDecode:               return "link"
        case .base64Encode, .base64Decode:         return "number"
        case .escapeHTML, .unescapeHTML:           return "chevron.left.forwardslash.chevron.right"
        case .jsonPretty, .jsonMinify:             return "curlybraces"
        case .linesSort, .linesDedup, .linesReverse: return "list.bullet"
        case .hexToRGB, .rgbToHex:                 return "paintpalette"
        }
    }

    /// Whether this transform makes sense for the given content type.
    /// Keeps the menu uncluttered — e.g. JSON transforms only surface
    /// on text/code clips, colour transforms only on colour clips.
    func applicable(to contentType: ContentType) -> Bool {
        switch self {
        case .hexToRGB, .rgbToHex:
            return contentType == .color
        case .jsonPretty, .jsonMinify,
             .linesSort, .linesDedup, .linesReverse:
            return contentType == .text || contentType == .code
        default:
            return contentType != .image
        }
    }

    /// Apply the transform to a string. Returns nil when the input is
    /// incompatible (e.g. invalid JSON for the JSON transforms). Callers
    /// should surface a subtle UI error in that case.
    func apply(to input: String) -> String? {
        switch self {
        case .upperCase:  return input.uppercased()
        case .lowerCase:  return input.lowercased()
        case .titleCase:  return input.capitalized

        case .snakeCase:  return Self.rewriteIdentifier(input, joiner: "_", lowercased: true)
        case .kebabCase:  return Self.rewriteIdentifier(input, joiner: "-", lowercased: true)
        case .camelCase:
            let parts = Self.identifierParts(from: input)
            guard let first = parts.first?.lowercased() else { return input }
            let tail = parts.dropFirst().map { $0.capitalized }
            return ([first] + tail).joined()

        case .trimWhitespace:
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        case .collapseWhitespace:
            return input
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        case .urlEncode:
            return input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        case .urlDecode:
            return input.removingPercentEncoding

        case .base64Encode:
            return Data(input.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: input) else { return nil }
            return String(data: data, encoding: .utf8)

        case .escapeHTML:
            var s = input
            s = s.replacingOccurrences(of: "&", with: "&amp;")
            s = s.replacingOccurrences(of: "<", with: "&lt;")
            s = s.replacingOccurrences(of: ">", with: "&gt;")
            s = s.replacingOccurrences(of: "\"", with: "&quot;")
            s = s.replacingOccurrences(of: "'", with: "&#39;")
            return s
        case .unescapeHTML:
            var s = input
            s = s.replacingOccurrences(of: "&lt;", with: "<")
            s = s.replacingOccurrences(of: "&gt;", with: ">")
            s = s.replacingOccurrences(of: "&quot;", with: "\"")
            s = s.replacingOccurrences(of: "&#39;", with: "'")
            s = s.replacingOccurrences(of: "&amp;", with: "&")
            return s

        case .jsonPretty:
            guard let data = input.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let out = try? JSONSerialization.data(
                      withJSONObject: obj,
                      options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
                  ),
                  let str = String(data: out, encoding: .utf8)
            else { return nil }
            return str
        case .jsonMinify:
            guard let data = input.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let out = try? JSONSerialization.data(
                      withJSONObject: obj,
                      options: [.fragmentsAllowed]
                  ),
                  let str = String(data: out, encoding: .utf8)
            else { return nil }
            return str

        case .linesSort:
            return input
                .components(separatedBy: .newlines)
                .sorted()
                .joined(separator: "\n")
        case .linesDedup:
            var seen = Set<String>()
            let unique = input.components(separatedBy: .newlines).filter {
                seen.insert($0).inserted
            }
            return unique.joined(separator: "\n")
        case .linesReverse:
            return input
                .components(separatedBy: .newlines)
                .reversed()
                .joined(separator: "\n")

        case .hexToRGB:
            return ColorTransforms.hexToRGB(input)
        case .rgbToHex:
            return ColorTransforms.rgbToHex(input)
        }
    }

    // MARK: private helpers

    /// Tokenise an identifier-like string so snake/kebab/camel case
    /// transforms share the same splitting logic: splits on spaces,
    /// underscores, hyphens, and interior caseChange boundaries
    /// (e.g. "fooBar" → ["foo", "Bar"]).
    private static func identifierParts(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        // Split on separators first.
        let coarse = trimmed
            .components(separatedBy: CharacterSet(charactersIn: " _-."))
            .filter { !$0.isEmpty }

        // Then split each coarse chunk on caseChange boundaries.
        var parts: [String] = []
        for chunk in coarse {
            var buffer = ""
            for ch in chunk {
                if ch.isUppercase, !buffer.isEmpty,
                   let last = buffer.last, !last.isUppercase {
                    parts.append(buffer)
                    buffer = String(ch)
                } else {
                    buffer.append(ch)
                }
            }
            if !buffer.isEmpty { parts.append(buffer) }
        }
        return parts
    }

    private static func rewriteIdentifier(
        _ text: String,
        joiner: String,
        lowercased: Bool
    ) -> String {
        let parts = identifierParts(from: text)
        let transformed = lowercased ? parts.map { $0.lowercased() } : parts
        return transformed.joined(separator: joiner)
    }
}

// MARK: - Colour Transforms

enum ColorTransforms {
    /// "#RRGGBB" or "#RGB" → "rgb(R, G, B)" (also handles 8-char alpha).
    static func hexToRGB(_ text: String) -> String? {
        var hex = text.trimmingCharacters(in: .whitespaces).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }

        // Expand shorthand like "F0A" → "FF00AA".
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }

        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else { return nil }

        if hex.count == 6 {
            let r = Int((value >> 16) & 0xFF)
            let g = Int((value >> 8) & 0xFF)
            let b = Int(value & 0xFF)
            return "rgb(\(r), \(g), \(b))"
        } else {
            let r = Int((value >> 24) & 0xFF)
            let g = Int((value >> 16) & 0xFF)
            let b = Int((value >> 8) & 0xFF)
            let a = Double(value & 0xFF) / 255.0
            return String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, a)
        }
    }

    /// "rgb(R, G, B)" → "#RRGGBB". Accepts whitespace and mixed case.
    static func rgbToHex(_ text: String) -> String? {
        let digits = text
            .components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
        guard digits.count >= 3 else { return nil }
        let r = max(0, min(255, digits[0]))
        let g = max(0, min(255, digits[1]))
        let b = max(0, min(255, digits[2]))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - QR Code

enum QRCodeGenerator {
    /// Render `text` as a QR code image at the requested size. Returns
    /// nil for strings CoreImage rejects (extremely long payloads, etc).
    /// `size` is the pixel dimension of the longer side; the result is
    /// always square.
    static func image(from text: String, size: CGFloat = 512) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // CoreImage output is tiny (~30px) — scale up cleanly.
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        return nsImage
    }

    /// Render `text` as a QR, JPEG-compressed, ready for the pasteboard.
    /// Returns nil on failure.
    static func jpegData(from text: String, size: CGFloat = 512) -> Data? {
        guard let img = image(from: text, size: size),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
