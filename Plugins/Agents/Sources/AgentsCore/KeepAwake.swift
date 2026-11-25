import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// What keeps a Mac from sleeping by itself, as the system has it: an
/// assertion of this process's own, and the others'.
public protocol SleepHolding: AnyObject {
    /// Holds the Mac awake under `name` — what `pmset -g assertions` shows;
    /// false when the system refused.
    func hold(named name: String) -> Bool
    func release()
    /// The other processes that keep it from sleeping by itself now, by name:
    /// Amphetamine, caffeinate. macOS's own services are not named — powerd's
    /// "while the display is on", sharingd's moment of AirDrop: noise to the
    /// person, and gone by themselves.
    func others() -> [String]
    /// Whether the Mac has a lid: a battery inside. Closed, it sleeps
    /// whatever holds it — unless it is on power with a display attached, or
    /// in Amphetamine's closed-display mode.
    var hasALid: Bool { get }
}

/// The system's own: an IOKit power assertion, `PreventUserIdleSystemSleep`
/// — the Mac does not sleep by itself, and the display still does.
public final class SystemSleepHold: SleepHolding {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    public init() {}

    deinit { release() }

    public func hold(named name: String) -> Bool {
        guard !held else { return true }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString,
                                                 &assertion)
        held = result == kIOReturnSuccess
        return held
    }

    public func release() {
        guard held else { return }
        IOPMAssertionRelease(assertion)
        held = false
    }

    public func others() -> [String] {
        var copied: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess,
              let byProcess = copied?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let keepsAwake: Set<String> = [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep,
                                       kIOPMAssertionTypeNoIdleSleep]
        var names: Set<String> = []
        for (pid, assertions) in byProcess where pid.int32Value != me {
            guard assertions.contains(where: { keepsAwake.contains($0[kIOPMAssertionTypeKey] as? String ?? "") }) else {
                continue
            }
            let pid = pid.int32Value
            guard !Self.isTheSystems(pid) else { continue }
            let name = Self.name(of: pid)
            guard !name.isEmpty else { continue }
            names.insert(name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public var hasALid: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// A service of macOS's own: run from /System or /usr/libexec, or from
    /// /usr/sbin. `caffeinate` (/usr/bin) is somebody's choice and is named.
    static func isTheSystems(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        return ["/System/", "/usr/libexec/", "/usr/sbin/"].contains { path.hasPrefix($0) }
    }

    static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }
}

/// The Mac kept awake while an agent works (setting `keep_awake`, on until
/// switched off; 11-25): held while a session is in a turn and not waiting
/// for the person — a question waits through a sleep, a turn does not — and
/// let go as soon as none is. Amphetamine's sessions are never touched; who
/// else holds the Mac is only said.
///
/// A sleep is noticed afterwards, by the clocks: the wall clock goes on
/// through a sleep and the system's uptime does not, so a gap between them
/// that grew since the last look is the time the Mac slept.
@MainActor
public final class KeepAwake {
    let holder: any SleepHolding
    /// How many sessions are working, as last told.
    public private(set) var working = 0
    /// Whether this process holds the Mac now.
    public private(set) var holding = false
    /// Who else held it at the last look, and whether there is a lid.
    public private(set) var others: [String] = []
    public let hasALid: Bool
    /// The sessions that were working at the last look: a sleep after it
    /// stopped them.
    private(set) var workingAtLastLook: Set<UUID> = []
    private let clock: () -> (wall: Date, uptime: TimeInterval)
    private var lastLook: (wall: Date, uptime: TimeInterval)

    /// A gap shorter than this is the look running late, not a sleep.
    static let shortestSleep: TimeInterval = 60

    public init(holder: any SleepHolding = SystemSleepHold(),
                clock: @escaping () -> (wall: Date, uptime: TimeInterval) = {
                    (Date(), ProcessInfo.processInfo.systemUptime)
                }) {
        self.holder = holder
        self.clock = clock
        hasALid = holder.hasALid
        lastLook = clock()
    }

    /// Holds while `working` sessions run and the setting allows it; lets go
    /// otherwise. `name` is what the system shows as the holder.
    public func update(working sessions: Set<UUID>, enabled: Bool, name: String) {
        working = sessions.count
        if enabled, !sessions.isEmpty {
            if !holding {
                holding = holder.hold(named: name)
                others = holder.others()
            }
        } else if holding {
            holder.release()
            holding = false
        }
    }

    /// Who else holds the Mac, asked again — on the look's timer, not on every
    /// card: the system's list is a call into powerd.
    public func refreshOthers() {
        others = holding ? holder.others() : []
    }

    /// The sleep since the last look, if there was one, and the sessions it
    /// stopped. Taken as starting right after that look: at most one look
    /// early.
    public func look(working sessions: Set<UUID>) -> (from: Date, to: Date, stopped: Set<UUID>)? {
        let now = clock()
        defer {
            lastLook = now
            workingAtLastLook = sessions
        }
        let slept = now.wall.timeIntervalSince(lastLook.wall) - (now.uptime - lastLook.uptime)
        guard slept >= Self.shortestSleep else { return nil }
        return (lastLook.wall, lastLook.wall.addingTimeInterval(slept), workingAtLastLook)
    }

    /// Lets go for good: the process is ending.
    public func stop() {
        if holding { holder.release() }
        holding = false
    }
}
