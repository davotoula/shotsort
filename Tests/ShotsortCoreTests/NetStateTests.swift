import Testing
import Foundation
@testable import ShotsortCore

private func move(_ file: String, to dest: String) -> ManifestRecord {
    ManifestRecord(op: .move, file: file, from: "/i/\(file)", to: dest, at: "t")
}
private func revert(_ file: String, from dest: String) -> ManifestRecord {
    ManifestRecord(op: .revert, file: file, from: dest, to: "/i/\(file)", at: "t")
}

@Test func unknownFileIsInTheInbox() {
    #expect(NetState(records: []).location(of: "a.png") == .inbox)
}

@Test func aMoveRecordPutsTheFileAtItsDestination() {
    let s = NetState(records: [move("a.png", to: "/o/News/a.png")])
    #expect(s.location(of: "a.png") == .at("/o/News/a.png"))
}

@Test func aRevertSupersedesAnEarlierMove() {
    // The regression guard for the apply/undo interaction.
    let s = NetState(records: [
        move("a.png", to: "/o/News/a.png"),
        revert("a.png", from: "/o/News/a.png"),
    ])
    #expect(s.location(of: "a.png") == .inbox)
}

@Test func lastRecordWinsAcrossManyCycles() {
    let s = NetState(records: [
        move("a.png", to: "/o/News/a.png"),
        revert("a.png", from: "/o/News/a.png"),
        move("a.png", to: "/o/Travel/a.png"),
    ])
    #expect(s.location(of: "a.png") == .at("/o/Travel/a.png"))
}

@Test func filesAreTrackedIndependently() {
    let s = NetState(records: [
        move("a.png", to: "/o/News/a.png"),
        move("b.png", to: "/o/Travel/b.png"),
        revert("a.png", from: "/o/News/a.png"),
    ])
    #expect(s.location(of: "a.png") == .inbox)
    #expect(s.location(of: "b.png") == .at("/o/Travel/b.png"))
}
