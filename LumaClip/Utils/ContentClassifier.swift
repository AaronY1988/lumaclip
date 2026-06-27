// ContentClassifier.swift
// LumaClip - macOS Clipboard Manager
//
// Smart content classification using regex patterns and heuristics.
// Detects URLs, emails, phone numbers, code snippets, file paths,
// and hex color codes from clipboard text.

import Foundation

// MARK: - Content Classifier

struct ContentClassifier {

    // MARK: - Classification

    /// Classify clipboard text content into a ContentType
    static func classify(_ text: String) -> ContentType {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Order matters: more specific patterns first
        if isURL(trimmed)       { return .url }
        if isEmail(trimmed)     { return .email }
        if isPhone(trimmed)     { return .phone }
        if isColor(trimmed)     { return .color }
        if isFilePath(trimmed)  { return .path }
        if isCode(trimmed)      { return .code }

        return .text
    }

    // MARK: - Pattern Matchers

    /// URL: starts with http(s):// or www.
    private static func isURL(_ text: String) -> Bool {
        let pattern = #"^(https?://|www\.)[^\s]+"#
        return matches(text, pattern: pattern)
    }

    /// Email: standard email format
    private static func isEmail(_ text: String) -> Bool {
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return matches(text, pattern: pattern)
    }

    /// Phone: various phone number formats
    private static func isPhone(_ text: String) -> Bool {
        let pattern = #"^[\+]?[(]?[0-9]{1,4}[)]?[-\s\./0-9]{7,15}$"#
        return matches(text, pattern: pattern)
    }

    /// Hex color: #RGB, #RRGGBB, #RRGGBBAA
    private static func isColor(_ text: String) -> Bool {
        let pattern = #"^#([A-Fa-f0-9]{3}|[A-Fa-f0-9]{6}|[A-Fa-f0-9]{8})$"#
        return matches(text, pattern: pattern)
    }

    /// File path: Unix or macOS path patterns
    private static func isFilePath(_ text: String) -> Bool {
        let pattern = #"^[/~][\w\-./\s]+"#
        return text.count < 500 && matches(text, pattern: pattern)
    }

    /// Code: heuristic detection based on common code patterns
    private static func isCode(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)

        // Multi-line with indentation suggests code
        if lines.count >= 3 {
            let indentedLines = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
            if Double(indentedLines.count) / Double(lines.count) > 0.4 {
                return true
            }
        }

        // Common code patterns
        let codePatterns = [
            #"(func |function |def |class |struct |enum |protocol )"#,
            #"(import |require\(|from .+ import)"#,
            #"(if \(|for \(|while \(|switch \()"#,
            #"[{};]\s*$"#,
            #"(var |let |const |int |string |bool )"#,
            #"(return |throw |catch |try )"#,
            #"(=>|->|\|>)"#,
            #"^\s*(//|/\*|#|--)"#,
        ]

        var matchCount = 0
        for pattern in codePatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                matchCount += 1
            }
        }

        // If 2+ code patterns match, it's likely code
        return matchCount >= 2
    }

    // MARK: - Regex Helper

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
