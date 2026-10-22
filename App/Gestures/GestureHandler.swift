// Gesture policy lives in the host's active interaction entry points.
// Keep only the shared value type, not an unused parallel dispatcher.
enum SwipeDirection {
    case left, right, up, down
}
