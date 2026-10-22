/// A single presentation policy for compact layout metrics and rendered content.
/// Includes the enabled Battery idle fallback; nil means no module content.
enum CompactModuleSelection {
    static func resolve(
        active: ActiveModule?,
        explicitSelection: ActiveModule?,
        presentationHold: ActiveModule?,
        hasVerifiedAgentAttention: Bool,
        hasMedia: Bool,
        mediaIsPlaying: Bool,
        batteryEnabled: Bool,
        isCompact: Bool,
        idleModule: ActiveModule? = .builtIn(.battery),
        hasVerifiedAgentActivity: Bool = false,
        isKeepingAwake: Bool = false
    ) -> ActiveModule? {
        if let presentationHold { return presentationHold }
        let idle = idleModule == .builtIn(.battery) && !batteryEnabled ? nil : idleModule
        // Closing a browsing session must not pin its last tab as a live activity.
        if isCompact {
            if hasVerifiedAgentAttention { return .builtIn(.agent) }
            if isKeepingAwake { return .builtIn(.tools) }
            if hasMedia && mediaIsPlaying { return .builtIn(.nowPlaying) }
            if hasVerifiedAgentActivity { return .builtIn(.agent) }
            return idle
        }
        if let explicitSelection { return explicitSelection }
        if hasVerifiedAgentAttention { return .builtIn(.agent) }
        guard let active else {
            if hasMedia && mediaIsPlaying { return .builtIn(.nowPlaying) }
            return idle
        }
        // Preserve existing content priority: paused metadata does not displace
        // another module, and a visible volume HUD only yields after dismissal.
        if hasMedia && mediaIsPlaying {
            switch active {
            case .builtIn(.battery), .builtIn(.shelf):
                return .builtIn(.nowPlaying)
            default:
                break
            }
        }
        return active
    }
}
