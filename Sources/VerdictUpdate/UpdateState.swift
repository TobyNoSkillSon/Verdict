import Foundation

/// The app's update flow as a pure state machine (the menu item and popup follow `phase`):
///
///     idle ──checked(newer)──▶ available ──confirm──▶ downloading ──verified(idle)──▶ installing ──▶ (the app quits)
///       ▲                        │  ▲                    │   └─verified(loading)─▶ waitingForLoad ──loadFinished──┘
///       └──checked(nil)──────────┘  └──────failed(reason): the reason is shown, the offer stays──────────┘
///
/// A check never interrupts a download or install; a failed check keeps what was known.
public enum UpdatePhase: Equatable, Sendable {
    case idle
    case available(ReleaseInfo)
    case downloading(ReleaseInfo)
    case waitingForLoad(ReleaseInfo)
    case installing(ReleaseInfo)

    public var release: ReleaseInfo? {
        switch self {
        case .idle: return nil
        case .available(let r), .downloading(let r), .waitingForLoad(let r), .installing(let r): return r
        }
    }
    /// True while an update is being downloaded or installed.
    public var busy: Bool {
        switch self { case .downloading, .waitingForLoad, .installing: return true; default: return false }
    }
    /// The menu item under "Support the developer…", or nil (no item) when there is nothing newer.
    public var menuTitle: String? {
        switch self {
        case .idle: return nil
        case .available(let r): return "Update to \(r.version)…"
        case .downloading(let r): return "Downloading \(r.version)…"
        case .waitingForLoad(let r): return "Update to \(r.version) after the model loads…"
        case .installing(let r): return "Installing \(r.version)…"
        }
    }
}

public enum UpdateEvent: Equatable, Sendable {
    /// A check finished: the release to offer, or nil when this version is current.
    case checked(ReleaseInfo?)
    case checkFailed(String)
    /// "Update Now" in the popup.
    case confirmed
    /// The download is verified; `modelLoading` says whether a model is loading right now.
    case verified(modelLoading: Bool)
    case loadFinished
    case failed(String)
}

public struct UpdateMachine: Equatable, Sendable {
    public private(set) var phase: UpdatePhase = .idle
    /// The last install failure (the item's tooltip); cleared when an update starts.
    public private(set) var lastError: String?
    public init(phase: UpdatePhase = .idle) { self.phase = phase }

    /// Applies an event; returns false (and changes nothing) when it does not apply in the current phase.
    @discardableResult
    public mutating func handle(_ event: UpdateEvent) -> Bool {
        switch (phase, event) {
        case (.idle, .checked(let release)), (.available, .checked(let release)):
            phase = release.map { .available($0) } ?? .idle
        case (_, .checkFailed):
            break                           // silent: the next check tries again; what was known stays
        case (.available(let r), .confirmed):
            lastError = nil; phase = .downloading(r)
        case (.downloading(let r), .verified(let loading)):
            phase = loading ? .waitingForLoad(r) : .installing(r)
        case (.waitingForLoad(let r), .loadFinished):
            phase = .installing(r)
        case (.downloading(let r), .failed(let reason)), (.waitingForLoad(let r), .failed(let reason)), (.installing(let r), .failed(let reason)):
            lastError = reason; phase = .available(r)
        default:
            return false
        }
        return true
    }
}

/// True when the periodic check is due: never checked, or `interval` (24 hours) since the last check.
public func updateCheckDue(last: Date?, now: Date = Date(), interval: TimeInterval = 24 * 60 * 60) -> Bool {
    guard let last else { return true }
    return now.timeIntervalSince(last) >= interval || now < last
}
