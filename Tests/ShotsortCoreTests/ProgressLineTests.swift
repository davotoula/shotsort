import Testing
import Foundation
@testable import ShotsortCore

@Test func barFormFillsTheAvailableWidth() {
    // width 30: head "extracting  [" is 13, tail "]  5/10   50%" is 13,
    // leaving 3 cells and a total of 29 — one short of the width, which is
    // what keeps the line off a second row.
    let line = ProgressLine.render(label: "extracting", done: 5, total: 10,
                                   eta: nil, style: .bar, width: 30)
    #expect(line == "extracting  [█░░]  5/10   50%")
    #expect(line.count == 29)
}

@Test func barFormAtZeroAndAtCompletion() {
    let zero = ProgressLine.render(label: "extracting", done: 0, total: 10,
                                   eta: nil, style: .bar, width: 30)
    #expect(zero == "extracting  [░░░░]  0/10   0%")

    let done = ProgressLine.render(label: "extracting", done: 10, total: 10,
                                   eta: nil, style: .bar, width: 30)
    #expect(done == "extracting  [█]  10/10   100%")
}

@Test func barFormWithAnEtaAtEightyColumns() {
    let line = ProgressLine.render(label: "extracting", done: 712, total: 1494,
                                   eta: 161, style: .bar, width: 80)
    #expect(line == "extracting  ["
            + String(repeating: "█", count: 17)
            + String(repeating: "░", count: 20)
            + "]  712/1494   47%   eta 2m41s")
    #expect(line.count == 79)
}

@Test func compactFormKeepsTheLabel() {
    // The bar is the least valuable field to drop; the verb is the only word
    // saying WHAT is happening.
    let line = ProgressLine.render(label: "classifying", done: 712,
                                   total: 1494, eta: 161, style: .compact,
                                   width: 40)
    #expect(line == "classifying 712/1494 47% eta 2m41s")
}

@Test func aNilEtaOmitsTheFieldEntirely() {
    let compact = ProgressLine.render(label: "extracting", done: 2,
                                      total: 1494, eta: nil, style: .compact,
                                      width: 80)
    #expect(compact == "extracting 2/1494 0%")
}

@Test func thePercentageFloorsSoOneHundredMeansFinished() {
    // Rounding would print 100% at 1493 of 1494 — on the one run where the
    // outstanding record is the one being waited for.
    let line = ProgressLine.render(label: "extracting", done: 1493,
                                   total: 1494, eta: nil, style: .compact,
                                   width: 80)
    #expect(line == "extracting 1493/1494 99%")
}

@Test func aZeroTotalDoesNotDivideByZero() {
    let line = ProgressLine.render(label: "extracting", done: 0, total: 0,
                                   eta: nil, style: .bar, width: 30)
    #expect(line == "extracting  [░░░░░]  0/0   0%")
}

@Test func aNegativeDoneDoesNotTrapAndYieldsAnEmptyBar() {
    // `render` is public and takes arbitrary `Int`s. Without a floor on
    // `filled`, `cells * done / total` goes negative here (19 * -50 / 10 =
    // -95) and `String(repeating:count:)` traps on the negative count.
    let line = ProgressLine.render(label: "extracting", done: -50, total: 10,
                                   eta: nil, style: .bar, width: 50)
    #expect(line == "extracting  [" + String(repeating: "░", count: 19)
                   + "]  -50/10   -500%")
}

@Test func durationsAreCompact() {
    #expect(ProgressLine.duration(45) == "45s")
    #expect(ProgressLine.duration(161) == "2m41s")
    #expect(ProgressLine.duration(3725) == "1h02m")
}
