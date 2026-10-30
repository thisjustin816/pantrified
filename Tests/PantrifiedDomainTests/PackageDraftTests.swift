import Foundation
import Testing
@testable import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func makeDraft() -> PackageDraft {
    PackageDraft(spaceID: SpaceID())
}

@Suite("Draft recognition proposals")
struct DraftProposalTests {
    @Test("a new draft is empty and carries no confirmed fields")
    func emptyDraft() {
        let draft = makeDraft()

        #expect(draft.name.value == nil)
        #expect(draft.name.source == nil)
        #expect(draft.location == nil)
    }

    @Test("proposals fill empty fields as recognized values")
    func proposalFillsEmpty() {
        var draft = makeDraft()
        draft.apply(PackageProposal(name: "Greek yogurt", quantity: .full))

        #expect(draft.name.value == "Greek yogurt")
        #expect(draft.name.source == .recognized)
        #expect(draft.quantity.value == .full)
    }

    @Test("a later proposal replaces an earlier recognized value")
    func laterProposalReplacesRecognized() {
        var draft = makeDraft()
        draft.apply(PackageProposal(name: "Yoghurt"))
        draft.apply(PackageProposal(name: "Greek yogurt"))

        #expect(draft.name.value == "Greek yogurt")
    }

    @Test("a user edit wins over a delayed proposal")
    func userEditWins() {
        var draft = makeDraft()
        draft.name.confirm("Oat milk")
        draft.apply(PackageProposal(name: "Soy milk"))

        #expect(draft.name.value == "Oat milk")
        #expect(draft.name.source == .userConfirmed)
    }

    @Test("a user who clears a field keeps it cleared against later proposals")
    func userClearWins() {
        var draft = makeDraft()
        draft.apply(PackageProposal(printedDate: PrintedDate(label: .useBy, date: t0)))
        draft.printedDate.confirm(nil)
        draft.apply(PackageProposal(printedDate: PrintedDate(label: .useBy, date: t0.addingTimeInterval(86_400))))

        #expect(draft.printedDate.value == nil)
        #expect(draft.printedDate.source == .userConfirmed)
    }

    @Test("a proposal only touches the fields it carries")
    func partialProposal() {
        var draft = makeDraft()
        draft.name.confirm("Butter")
        draft.apply(PackageProposal(quantity: .aboutHalf))

        #expect(draft.name.value == "Butter")
        #expect(draft.quantity.value == .aboutHalf)
    }

    @Test("a barcode is recorded as product evidence and never merges drafts by itself")
    func barcodeIsEvidence() {
        var a = makeDraft()
        var b = makeDraft()
        a.barcode = "0123456789012"
        b.barcode = "0123456789012"

        #expect(a.id != b.id)
    }
}

@Suite("Draft readiness")
struct DraftReadinessTests {
    @Test("a draft with a name and location is ready even with no quantity or date")
    func readyWithoutQuantityOrDate() {
        var draft = makeDraft()
        draft.name.confirm("Mystery leftovers")
        draft.location = LocationID()

        #expect(draft.readiness == .ready)
    }

    @Test("a missing name blocks put-away")
    func needsName() {
        var draft = makeDraft()
        draft.location = LocationID()

        #expect(draft.readiness == .needs([.name]))
    }

    @Test("a whitespace-only name counts as missing")
    func whitespaceName() {
        var draft = makeDraft()
        draft.name.confirm("   ")
        draft.location = LocationID()

        #expect(draft.readiness == .needs([.name]))
    }

    @Test("a missing location blocks put-away")
    func needsLocation() {
        var draft = makeDraft()
        draft.name.confirm("Rice")

        #expect(draft.readiness == .needs([.location]))
    }

    @Test("every missing requirement is reported")
    func reportsAll() {
        #expect(makeDraft().readiness == .needs([.name, .location]))
    }
}

@Suite("Draft bulk location assignment")
struct DraftBulkLocationTests {
    @Test("assigns the location to the chosen drafts only and can be undone")
    func assignAndUndo() {
        let first = LocationID()
        let second = LocationID()
        var a = makeDraft()
        let b = makeDraft()
        let c = makeDraft()
        a.location = first
        var batch = DraftBatch([a, b, c])

        let undo = batch.assignLocation(second, to: [b.id, a.id])
        #expect(batch.drafts.map(\.location) == [second, second, nil])

        batch.undo(undo)
        #expect(batch.drafts.map(\.location) == [first, nil, nil])
    }

    @Test("ids that are not in the batch are ignored")
    func unknownIDsIgnored() {
        var batch = DraftBatch([makeDraft()])
        let undo = batch.assignLocation(LocationID(), to: [PackageID()])

        #expect(batch.drafts[0].location == nil)
        batch.undo(undo)
        #expect(batch.drafts[0].location == nil)
    }
}
