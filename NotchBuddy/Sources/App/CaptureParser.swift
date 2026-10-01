import Foundation

// MARK: - Parsed capture (preview + input to CaptureStore)

struct ParsedCapture: Equatable, Sendable {
    var kind: CaptureKind
    var title: String
    var url: URL?
    var date: Date?
    var endDate: Date?
    var hasTime: Bool
}

/// Turns one line of free text into a note, link, reminder or event.
/// Offline and instant: uses Foundation's NSDataDetector, no network, no AI.
///
///   "call Sam tomorrow 3pm"            → reminder, tomorrow 15:00
///   "shoot with Mia fri 10am to 12pm"  → event, Friday 10:00–12:00
///   "https://pinterest.com/pin/…"      → link
///   "e: dentist monday 9am"            → event (prefix forces the kind)
///   "brand colours: rust + cream"      → note
enum CaptureParser {

    // NSDataDetector / NSRegularExpression are immutable and Sendable.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let timeHint = try? NSRegularExpression(
        pattern: #"\d{1,2}:\d{2}|\d{1,2}\s*(am|pm|a\.m\.|p\.m\.|h)\b|\b(noon|midday|midnight|morning|afternoon|evening|tonight)\b|\bat\s+\d{1,2}\b|\d{1,2}\s*[-–]\s*\d{1,2}|\bin\s+(an?|\d+)\s*(min|mins|minutes?|hours?|hrs?|h)\b"#,
        options: [.caseInsensitive])
    private static let reminderLead = try? NSRegularExpression(
        pattern: #"^\s*(remind\s+me\s+(to\s+)?|remember\s+(to\s+)?|don'?t\s+forget\s+(to\s+)?|to\s*do:?\s+|todo:?\s+)"#,
        options: [.caseInsensitive])
    private static let eventWords = try? NSRegularExpression(
        pattern: #"\b(meeting|meet|lunch|dinner|breakfast|brunch|coffee|drinks|shoot|photoshoot|appointment|appt|interview|party|session|class|flight|gig|show|call with|zoom|facetime)\b"#,
        options: [.caseInsensitive])

    /// Explicit prefixes that force a kind ("n:", "link:", "r:", "e:" …).
    private static let prefixes: [(String, CaptureKind)] = [
        ("note", .note), ("n", .note),
        ("link", .link), ("l", .link),
        ("reminder", .reminder), ("remind", .reminder), ("todo", .reminder), ("r", .reminder),
        ("event", .event), ("cal", .event), ("e", .event),
    ]

    static func parse(_ raw: String, forcing forced: CaptureKind? = nil, now: Date = .now) -> ParsedCapture {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefixKind: CaptureKind? = nil

        // 1. Prefix ("e: dentist monday") — only when followed by ':' so "notes app" stays a note
        for (p, kind) in prefixes {
            let lower = text.lowercased()
            if lower.hasPrefix(p + ":") {
                text = String(text.dropFirst(p.count + 1)).trimmingCharacters(in: .whitespaces)
                prefixKind = kind
                break
            }
        }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 2. Link
        var url: URL? = nil
        var urlRange: NSRange? = nil
        if let m = linkDetector?.firstMatch(in: text, options: [], range: full), let u = m.url,
           u.scheme == "http" || u.scheme == "https" {
            url = u
            urlRange = m.range
        }

        // 3. Date (ignore matches that sit inside the URL)
        var date: Date? = nil
        var endDate: Date? = nil
        var hasTime = false
        var dateRange: NSRange? = nil
        let dateMatches = dateDetector?.matches(in: text, options: [], range: full) ?? []
        if let m = dateMatches.first(where: { m in urlRange.map { NSIntersectionRange($0, m.range).length == 0 } ?? true }),
           let d = m.date {
            let matched = ns.substring(with: m.range)
            let span = NSRange(location: 0, length: (matched as NSString).length)
            hasTime = m.duration > 0 || (timeHint?.firstMatch(in: matched, options: [], range: span) != nil)
            let cal = Calendar.current
            date = hasTime ? d : cal.startOfDay(for: d)
            if m.duration > 0 { endDate = d.addingTimeInterval(m.duration) }
            // "3pm" typed at 5pm means tomorrow 3pm, not two hours ago
            if hasTime, let start = date, start < now, cal.isDate(start, inSameDayAs: now),
               !matched.lowercased().contains("today") {
                date = cal.date(byAdding: .day, value: 1, to: start)
                endDate = endDate.flatMap { cal.date(byAdding: .day, value: 1, to: $0) }
            }
            dateRange = m.range
        }

        // 4. Kind
        let hasReminderLead = reminderLead?.firstMatch(in: text, options: [], range: full) != nil
        let hasEventWord = eventWords?.firstMatch(in: text, options: [], range: full) != nil
        let detected: CaptureKind
        if let prefixKind {
            detected = prefixKind
        } else if date != nil {
            if hasReminderLead { detected = .reminder }
            else if endDate != nil || hasEventWord { detected = .event }
            else { detected = .reminder }
        } else if url != nil {
            detected = .link
        } else if hasReminderLead {
            detected = .reminder
        } else {
            detected = .note
        }
        let kind = forced ?? detected

        // 5. Title: strip URL + date phrase (not for notes, which keep the full text) + lead phrase
        var title: String
        if kind == .note {
            title = text
        } else {
            let mutable = NSMutableString(string: text)
            let cuts = [urlRange, kind == .link ? nil : dateRange].compactMap { $0 }
                .sorted { $0.location > $1.location }
            for r in cuts { mutable.replaceCharacters(in: r, with: " ") }
            title = String(mutable)
            if let lead = reminderLead {
                title = lead.stringByReplacingMatches(in: title, options: [],
                                                      range: NSRange(location: 0, length: (title as NSString).length),
                                                      withTemplate: "")
            }
            title = cleanTitle(title)
        }

        // Events always need a start; default to the next full hour
        if kind == .event && date == nil {
            let cal = Calendar.current
            let nextHour = cal.date(byAdding: .hour, value: 1, to: now) ?? now
            date = cal.date(bySettingHour: cal.component(.hour, from: nextHour), minute: 0, second: 0, of: nextHour)
            hasTime = true
        }

        return ParsedCapture(kind: kind, title: title, url: url, date: date,
                             endDate: kind == .event ? endDate : nil,
                             hasTime: hasTime)
    }

    /// Collapse whitespace, drop dangling prepositions left behind by the date cut ("call Sam at" → "call Sam").
    static func cleanTitle(_ s: String) -> String {
        let dangling: Set<String> = ["at", "on", "by", "for", "from", "until", "till", "to", "@", "-", "–", "—", ",", "·", "in"]
        var words = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, dangling.contains(first.lowercased()) || first == ":" { words.removeFirst() }
        var out = words.joined(separator: " ")
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-–—·"))
        if let f = out.first { out = f.uppercased() + out.dropFirst() }
        return out
    }
}
