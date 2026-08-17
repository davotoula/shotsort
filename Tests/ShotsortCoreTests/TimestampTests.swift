import Testing
import Foundation
@testable import ShotsortCore

@Test func parsesTheAndroidScreenshotPattern() {
    let (ts, source) = Timestamp.parse(filename: "Screenshot_20260420-135611.png",
                                       mtime: Date(timeIntervalSince1970: 0))
    #expect(ts == "2026-04-20T13:56:11")
    #expect(source == .filename)
}

@Test func toleratesSuffixedVariants() {
    // The collection contains names like Screenshot_20250527-154122~2.png
    let (ts, source) = Timestamp.parse(filename: "Screenshot_20250527-154122~2.png",
                                       mtime: Date(timeIntervalSince1970: 0))
    #expect(ts == "2025-05-27T15:41:22")
    #expect(source == .filename)
}

@Test func fallsBackToMtimeWhenThePatternDoesNotMatch() throws {
    let mtime = Date(timeIntervalSince1970: 1_754_659_331)
    let (ts, source) = Timestamp.parse(filename: "IMG_0042.png", mtime: mtime)
    #expect(source == .mtime)
    // Assert the value, not just the branch: a fallback that returns an
    // empty or malformed string would otherwise pass.
    #expect(ts == mtime.formatted(.iso8601))
    #expect(try Date.ISO8601FormatStyle().parse(ts) == mtime)
}
