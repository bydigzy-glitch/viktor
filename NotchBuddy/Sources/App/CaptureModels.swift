import Foundation

// MARK: - Quick capture kind

enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case note, link, reminder, event

    var label: String {
        switch self {
        case .note:     return "Note"
        case .link:     return "Link"
        case .reminder: return "Reminder"
        case .event:    return "Event"
        }
    }

    var icon: String {
        switch self {
        case .note:     return "note.text"
        case .link:     return "link"
        case .reminder: return "bell"
        case .event:    return "calendar"
        }
    }

    var color: String {
        switch self {
        case .note:     return "#E879F9"
        case .link:     return "#38BDF8"
        case .reminder: return "#F5A524"
        case .event:    return "#34D399"
        }
    }
}

// MARK: - Captured item (persisted in captures.json)

struct CaptureItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: CaptureKind
    var title: String
    var text: String            // original text, as typed
    var url: String?
    var linkTitle: String?      // fetched page title (links)
    var date: Date?             // due date (reminder) / start (event)
    var endDate: Date?          // end (event)
    var hasTime: Bool           // false = all-day / date only
    var createdAt: Date
    var done: Bool
    var externalId: String?     // EventKit calendarItemIdentifier when synced to Reminders / Calendar

    init(kind: CaptureKind, title: String, text: String, url: String? = nil,
         date: Date? = nil, endDate: Date? = nil, hasTime: Bool = true, externalId: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.text = text
        self.url = url
        self.date = date
        self.endDate = endDate
        self.hasTime = hasTime
        self.createdAt = .now
        self.done = false
        self.externalId = externalId
    }

    /// Short human date, e.g. "Tomorrow 3:00 PM", "Fri 10:00 – 12:00", "Today".
    var dateLabel: String? {
        guard let date else { return nil }
        return CaptureDateFormat.label(start: date, end: endDate, hasTime: hasTime)
    }

    /// Best display title for a link: page title, typed title, then host.
    var displayTitle: String {
        if kind == .link {
            if let t = linkTitle, !t.isEmpty { return t }
            if !title.isEmpty { return title }
            if let u = url, let host = URL(string: u)?.host { return host }
        }
        return title
    }
}

// MARK: - Result of a capture (shown as feedback under the field)

struct CaptureOutcome: Sendable {
    let item: CaptureItem
    let message: String
    let isWarning: Bool
}

// MARK: - Date formatting shared by the capture views

enum CaptureDateFormat {
    static func label(start: Date, end: Date?, hasTime: Bool, now: Date = .now) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(start) {
            day = "Today"
        } else if cal.isDateInTomorrow(start) {
            day = "Tomorrow"
        } else if cal.isDateInYesterday(start) {
            day = "Yesterday"
        } else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: start)).day,
                  days > 0, days < 7 {
            day = start.formatted(.dateTime.weekday(.abbreviated))
        } else {
            day = start.formatted(.dateTime.day().month(.abbreviated))
        }
        guard hasTime else { return day }
        let time = start.formatted(date: .omitted, time: .shortened)
        if let end, end > start, cal.isDate(end, inSameDayAs: start) {
            return "\(day) \(time) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(day) \(time)"
    }
}
