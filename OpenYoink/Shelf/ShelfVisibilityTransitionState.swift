/// Identifies the latest visibility intent without restarting identical requests.
/// Animation completions must match both the intent and its generation.
struct ShelfVisibilityTransitionState {
    private(set) var isVisible: Bool?
    private(set) var generation: UInt = 0

    mutating func request(visible: Bool) -> UInt? {
        guard isVisible != visible else { return nil }
        isVisible = visible
        generation &+= 1
        return generation
    }

    func isCurrent(_ generation: UInt, visible: Bool) -> Bool {
        self.generation == generation && isVisible == visible
    }
}
