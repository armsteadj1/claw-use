import Foundation
import Testing
@testable import CUACore

// MARK: - Helpers

private func makeElement(role: String, label: String?, identifier: String? = nil) -> Element {
    Element(ref: "tmp", role: role, label: label, value: nil, placeholder: nil,
            enabled: true, focused: false, selected: false, actions: ["click"],
            identifier: identifier)
}

// MARK: - Stable Refs Tests

/// Tests for RefStabilityManager — the core of the stable-refs feature (issue #12).
/// Each test exercises a specific behaviour: same-element ref persistence, new-element
/// allocation, tombstoning on disappearance, and ref reclamation on return.

@Test func stableRefsKeepsSameRef() throws {
    // An element seen in snapshot 1 must get the same ref in snapshot 2.
    let mgr = RefStabilityManager()

    let snap1 = [makeElement(role: "button", label: "Save")]
    let result1 = mgr.stabilize(elements: snap1)
    let ref1 = result1[0].ref

    let snap2 = [makeElement(role: "button", label: "Save")]
    let result2 = mgr.stabilize(elements: snap2)
    let ref2 = result2[0].ref

    #expect(ref1 == ref2, "same element must keep the same ref across snapshots")
    #expect(ref1 == "e1")
}

@Test func stableRefsNewElementGetsNextRef() throws {
    // A brand-new element gets the next sequential ref number.
    let mgr = RefStabilityManager()

    let snap1 = [makeElement(role: "button", label: "Save")]
    let result1 = mgr.stabilize(elements: snap1)
    #expect(result1[0].ref == "e1")

    // Add a second element in snapshot 2
    let snap2 = [
        makeElement(role: "button", label: "Save"),
        makeElement(role: "button", label: "Cancel"),
    ]
    let result2 = mgr.stabilize(elements: snap2)
    #expect(result2[0].ref == "e1", "existing element keeps e1")
    #expect(result2[1].ref == "e2", "new element gets e2")
}

@Test func stableRefsTombstoning() throws {
    // An element that disappears is tombstoned; its ref is NOT reused immediately.
    // A newly arriving different element must get a fresh ref (not the tombstoned one).
    let mgr = RefStabilityManager()
    mgr.tombstoneDuration = 60.0

    // Snapshot 1: two elements
    let snap1 = [
        makeElement(role: "button", label: "Save"),
        makeElement(role: "button", label: "Delete"),
    ]
    let result1 = mgr.stabilize(elements: snap1)
    #expect(result1[0].ref == "e1")
    #expect(result1[1].ref == "e2")
    #expect(mgr.tombstoneCount == 0)

    // Snapshot 2: "Delete" disappears → tombstoned
    let snap2 = [makeElement(role: "button", label: "Save")]
    let _ = mgr.stabilize(elements: snap2)
    #expect(mgr.tombstoneCount == 1, "disappeared element must be tombstoned")

    // Snapshot 3: a brand-new element appears (not "Delete" returning)
    let snap3 = [
        makeElement(role: "button", label: "Save"),
        makeElement(role: "button", label: "Archive"),
    ]
    let result3 = mgr.stabilize(elements: snap3)
    let archiveRef = result3.first(where: { $0.label == "Archive" })!.ref
    #expect(archiveRef == "e3", "new element must skip tombstoned ref e2 and get e3")
    #expect(mgr.tombstoneCount == 1, "tombstone for e2 still alive")
}

@Test func stableRefsReturnReclaimsOriginalRef() throws {
    // An element that disappears and then returns must reclaim its original ref.
    let mgr = RefStabilityManager()
    mgr.tombstoneDuration = 60.0

    // Snapshot 1
    let snap1 = [
        makeElement(role: "button", label: "Save"),
        makeElement(role: "button", label: "Delete"),
    ]
    let result1 = mgr.stabilize(elements: snap1)
    #expect(result1[1].ref == "e2")

    // Snapshot 2: "Delete" disappears
    let snap2 = [makeElement(role: "button", label: "Save")]
    let _ = mgr.stabilize(elements: snap2)
    #expect(mgr.tombstoneCount == 1)

    // Snapshot 3: "Delete" returns within the tombstone window
    let snap3 = [
        makeElement(role: "button", label: "Save"),
        makeElement(role: "button", label: "Delete"),
    ]
    let result3 = mgr.stabilize(elements: snap3)
    let deleteRef = result3.first(where: { $0.label == "Delete" })!.ref
    #expect(deleteRef == "e2", "returned element must reclaim its original ref e2")
    #expect(mgr.tombstoneCount == 0, "tombstone must be cleared on reclaim")
}

@Test func stableRefsAXIdentifierTakesPrecedenceOverLabel() throws {
    // When an element has an AX identifier, it must be tracked by identifier even if
    // its visible label changes between snapshots.
    let mgr = RefStabilityManager()

    let snap1 = [makeElement(role: "button", label: "Uploading…", identifier: "upload-btn")]
    let result1 = mgr.stabilize(elements: snap1)
    #expect(result1[0].ref == "e1")

    // Label changed (progress text updated) but AX identifier is the same
    let snap2 = [makeElement(role: "button", label: "Upload Complete", identifier: "upload-btn")]
    let result2 = mgr.stabilize(elements: snap2)
    #expect(result2[0].ref == "e1", "AX identifier-matched element must keep ref despite label change")
}

@Test func stableRefsTombstoneExpiryAllowsRefReuse() throws {
    // After the tombstone window expires, a new element with the same role/label may
    // receive a fresh ref (not the old one, since the mapping has been purged).
    var mgr = RefStabilityManager()
    mgr.tombstoneDuration = 0.0  // instant expiry for testing

    let snap1 = [makeElement(role: "button", label: "Save")]
    let _ = mgr.stabilize(elements: snap1)  // assigns e1

    // Element disappears — tombstoned
    let snap2: [Element] = []
    let _ = mgr.stabilize(elements: snap2)
    #expect(mgr.tombstoneCount == 1)

    // Wait for expiry: tombstoneDuration is 0, so next stabilize() call will purge
    // (expiry is set to now+0, which is already <= now on the next call)
    // Add a tiny sleep to ensure expiry
    Thread.sleep(forTimeInterval: 0.01)

    let snap3 = [makeElement(role: "button", label: "Save")]
    let result3 = mgr.stabilize(elements: snap3)
    #expect(mgr.tombstoneCount == 0, "expired tombstone must be purged")
    // After expiry, same label reappearing gets a new ref
    #expect(result3[0].ref == "e2", "after tombstone expiry, element gets a new ref")
}
