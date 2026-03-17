// FILE: LocalizableCatalogCoverageTests.swift
// Purpose: Guards String Catalog coverage for Simplified Chinese localizations.
// Layer: Unit Test
// Exports: LocalizableCatalogCoverageTests
// Depends on: XCTest

import XCTest

final class LocalizableCatalogCoverageTests: XCTestCase {
    func testStringCatalogProvidesSimplifiedChineseLocalizationForAllKeys() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CodexMobileTests
            .deletingLastPathComponent() // CodexMobile
            .appendingPathComponent("CodexMobile")
            .appendingPathComponent("Localizable.xcstrings")

        let data = try Data(contentsOf: fileURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        var missingKeys: [String] = []

        for (key, rawEntry) in strings {
            guard
                let entry = rawEntry as? [String: Any],
                let localizations = entry["localizations"] as? [String: Any],
                let zhHans = localizations["zh-Hans"] as? [String: Any],
                let stringUnit = zhHans["stringUnit"] as? [String: Any],
                let value = stringUnit["value"] as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                missingKeys.append(key)
                continue
            }
        }

        XCTAssertTrue(
            missingKeys.isEmpty,
            "Missing zh-Hans localization for keys: \(missingKeys.sorted().joined(separator: ", "))"
        )
    }
}
