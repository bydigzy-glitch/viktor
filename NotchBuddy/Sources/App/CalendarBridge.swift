import AppKit
import EventKit

/// Thin wrapper around EventKit: reminders go to Apple Reminders, events to Apple Calendar,
/// so they sync to iPhone and get native notifications. Access is requested the first
/// time the user captures a reminder / event, never at launch.
@MainActor
final class CalendarBridge {
    static let shared = CalendarBridge()

    private let store = EKEventStore()

    enum BridgeError: LocalizedError {
        case accessDenied(EKEntityType)
        case noDefaultList
        case noDefaultCalendar

        var errorDescription: String? {
            switch self {
            case .accessDenied(let type):
                return type == .reminder
                    ? "Reminders access is off (System Settings → Privacy → Reminders)"
                    : "Calendar access is off (System Settings → Privacy → Calendars)"
            case .noDefaultList:     return "No default Reminders list"
            case .noDefaultCalendar: return "No default calendar"
            }
        }
    }

    // MARK: - Access

    func hasAccess(_ type: EKEntityType) -> Bool {
        EKEventStore.authorizationStatus(for: type) == .fullAccess
    }

    func statusLabel(_ type: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:    return "Allowed"
        case .notDetermined: return "Asked on first use"
        case .writeOnly:     return "Add-only"
        default:             return "Off"
        }
    }

    /// Returns true when we may read + write this entity type, prompting once if undecided.
    func ensureAccess(_ type: EKEntityType) async -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:
            return true
        case .notDetermined:
            let granted = await requestAccess(type)
            if granted { store.reset() }   // pick up sources now that we may read them
            return granted
        default:
            return false
        }
    }

    private func requestAccess(_ type: EKEntityType) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let done: EKEventStoreRequestAccessCompletionHandler = { granted, _ in cont.resume(returning: granted) }
            if type == .reminder {
                store.requestFullAccessToReminders(completion: done)
            } else {
                store.requestFullAccessToEvents(completion: done)
            }
        }
    }

    // MARK: - Create

    /// Creates a reminder in the default list. Returns its identifier.
    func createReminder(title: String, due: Date?, hasTime: Bool, url: URL?, notes: String?) async throws -> String {
        guard await ensureAccess(.reminder) else { throw BridgeError.accessDenied(.reminder) }
        guard let list = store.defaultCalendarForNewReminders() else { throw BridgeError.noDefaultList }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        reminder.url = url
        reminder.notes = notes
        if let due {
            let parts: Set<Calendar.Component> = hasTime
                ? [.year, .month, .day, .hour, .minute]
                : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: due)
            if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// Creates an event in the default calendar. Returns its identifier.
    func createEvent(title: String, start: Date, end: Date?, allDay: Bool, url: URL?, notes: String?) async throws -> String {
        guard await ensureAccess(.event) else { throw BridgeError.accessDenied(.event) }
        guard let calendar = store.defaultCalendarForNewEvents else { throw BridgeError.noDefaultCalendar }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = calendar
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = end ?? (allDay ? start : start.addingTimeInterval(3600))
        event.url = url
        event.notes = notes
        try store.save(event, span: .thisEvent, commit: true)
        return event.calendarItemIdentifier
    }

    // MARK: - Update

    /// Mirrors the inbox checkbox onto the Reminders item. Silently no-ops if it was deleted there.
    func setReminderCompleted(id: String, _ completed: Bool) {
        guard hasAccess(.reminder),
              let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = completed
        try? store.save(reminder, commit: true)
    }

    /// Brings Reminders / Calendar to the front.
    func openApp(for kind: CaptureKind) {
        let bundleId: String
        switch kind {
        case .reminder: bundleId = "com.apple.reminders"
        case .event:    bundleId = "com.apple.iCal"
        default:        return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Today's agenda (inbox header)

    struct AgendaEntry: Identifiable, Sendable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
    }

    func todayAgenda(now: Date = .now) -> [AgendaEntry] {
        guard hasAccess(.event) else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.isAllDay || $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(4)
            .map { AgendaEntry(id: $0.calendarItemIdentifier, title: $0.title ?? "Untitled",
                               start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay) }
    }
}
