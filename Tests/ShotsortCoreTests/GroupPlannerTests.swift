import Testing
@testable import ShotsortCore

/// chars defaults above SignalGate.minChars so records carry signal unless a
/// test explicitly builds a no-signal one (chars < 12, no domain, no scene,
/// no faces).
private func rec(_ file: String, domain: String? = nil, scene: String? = nil,
                 chars: Int = 40, density: Double = 0.1,
                 faceArea: Double = 0) -> IndexRecord {
    IndexRecord(file: file, ts: "t", tsSource: .filename,
                ocr: "text for \(file)", chars: chars, blocks: 2,
                density: density,
                sceneRaw: scene.map {
                    [SceneObservation(identifier: $0, confidence: 0.8)]
                } ?? [],
                faces: faceArea > 0 ? 1 : 0, faceAreaMax: faceArea,
                domains: domain.map { [$0] } ?? [], error: nil)
}

@Test func aDomainPairFormsAGroup() {
    let (groups, singles) = GroupPlanner.plan([
        rec("a.png", domain: "d.com"), rec("b.png", domain: "d.com")])
    #expect(groups.count == 1)
    #expect(groups[0].evidence == "domain d.com")
    #expect(groups[0].members.map(\.file) == ["a.png", "b.png"])
    #expect(singles.isEmpty)
}

@Test func aDomainSingletonSpillsToSingles() {
    let (groups, singles) = GroupPlanner.plan([rec("a.png", domain: "d.com")])
    #expect(groups.isEmpty)
    #expect(singles.map(\.file) == ["a.png"])
}

@Test func aSceneTrioFormsAGroupButAPairDoesNot() {
    let trio = [rec("a.png", scene: "map"), rec("b.png", scene: "map"),
                rec("c.png", scene: "map")]
    let (groups, _) = GroupPlanner.plan(trio)
    #expect(groups.count == 1)
    #expect(groups[0].evidence == "scene map, faces absent, text sparse")

    let (pairGroups, pairSingles) = GroupPlanner.plan(Array(trio.prefix(2)))
    #expect(pairGroups.isEmpty)
    #expect(pairSingles.count == 2)
}

@Test func aDomainRecordNeverJoinsASceneGroup() {
    // Domain evidence outranks scene evidence: a record carrying both goes
    // to its domain bucket, so the map trio below stays one short of
    // sceneFloor and spills.
    let (groups, singles) = GroupPlanner.plan([
        rec("a.png", domain: "d.com", scene: "map"),
        rec("b.png", domain: "d.com", scene: "map"),
        rec("c.png", scene: "map"), rec("d.png", scene: "map")])
    #expect(groups.count == 1)
    #expect(groups[0].evidence == "domain d.com")
    #expect(singles.map(\.file) == ["c.png", "d.png"])
}

@Test func noSignalRecordsNeverGroup() {
    // Three records alike in having nothing: no domain, no scene, no faces,
    // chars below the gate. Shared absence is not shared evidence.
    let (groups, singles) = GroupPlanner.plan([
        rec("a.png", chars: 5), rec("b.png", chars: 5), rec("c.png", chars: 5)])
    #expect(groups.isEmpty)
    #expect(singles.count == 3)
}

@Test func scenelessRecordsWithSignalSpillToSingles() {
    // chars 40 carries signal, but topScene is "none" — absence of scene
    // evidence cannot form a scene group regardless of count.
    let (groups, singles) = GroupPlanner.plan([
        rec("a.png"), rec("b.png"), rec("c.png"), rec("d.png")])
    #expect(groups.isEmpty)
    #expect(singles.count == 4)
}

@Test func everyRecordLandsExactlyOnce() {
    let input = [
        rec("a.png", domain: "d.com"), rec("b.png", domain: "d.com"),
        rec("c.png", domain: "solo.com"),
        rec("d.png", scene: "map"), rec("e.png", scene: "map"),
        rec("f.png", scene: "map"),
        rec("g.png"), rec("h.png", chars: 5),
    ]
    let (groups, singles) = GroupPlanner.plan(input)
    let all = groups.flatMap { $0.members.map(\.file) } + singles.map(\.file)
    #expect(all.count == input.count)
    #expect(Set(all).count == input.count)
}

@Test func planIsDeterministicRegardlessOfInputOrder() {
    let input = [
        rec("a.png", domain: "d.com"), rec("b.png", domain: "d.com"),
        rec("c.png", scene: "map"), rec("d.png", scene: "map"),
        rec("e.png", scene: "map"), rec("f.png"),
    ]
    let forward = GroupPlanner.plan(input)
    let backward = GroupPlanner.plan(input.reversed())
    #expect(forward.groups.map(\.evidence) == backward.groups.map(\.evidence))
    #expect(forward.groups.map { $0.members.map(\.file) }
            == backward.groups.map { $0.members.map(\.file) })
    #expect(forward.singles.map(\.file) == backward.singles.map(\.file))
}
