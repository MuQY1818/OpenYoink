

struct DragAutoShowSession: Sendable, Equatable {
    private(set) var isDragging = false
    private(set) var shownAutomatically = false
    private(set) var receivedImport = false
    private var destinationSequenceNumber: Int?
    private var destinationDidEnd = false
    private var destinationAccepted = false
    private var keepAfterDrop = true

    mutating func dragBegan() {
        self = Self()
        isDragging = true
    }

    mutating func markShownAutomatically() {
        guard isDragging else { return }
        shownAutomatically = true
    }

    mutating func noteImport() {
        receivedImport = true
    }

    /// A real AppKit destination owns completion once it has seen this drag.
    /// Keep the identity after exit: draggingEnded also covers cancellation or
    /// a drop elsewhere. A late callback from an older drag cannot close a new one.
    mutating func destinationEntered(sequenceNumber: Int) {
        guard isDragging,
              destinationSequenceNumber == nil || destinationSequenceNumber == sequenceNumber else { return }
        destinationSequenceNumber = sequenceNumber
    }

    /// Returns a hide decision only after BOTH mouse-up and destination completion.
    mutating func destinationEnded(sequenceNumber: Int, accepted: Bool) -> Bool {
        guard destinationSequenceNumber == sequenceNumber, !destinationDidEnd else { return false }
        destinationDidEnd = true
        destinationAccepted = accepted
        return isDragging ? false : finish()
    }

    /// Explicit show/hide takes ownership away from automatic presentation.
    mutating func cancelAutomaticHide() {
        shownAutomatically = false
    }

    mutating func dragEnded(keepShelfOpenAfterDrop: Bool = true) -> Bool {
        guard isDragging else { return false }
        isDragging = false
        keepAfterDrop = keepShelfOpenAfterDrop
        if destinationSequenceNumber != nil && !destinationDidEnd { return false }
        return finish()
    }

    private mutating func finish() -> Bool {
        defer { self = Self() }
        let accepted = destinationSequenceNumber == nil ? receivedImport : destinationAccepted
        return shownAutomatically && !(accepted && keepAfterDrop)
    }
}
