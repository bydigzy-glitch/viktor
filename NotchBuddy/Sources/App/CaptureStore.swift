import AppKit

extension Notification.Name {
    /// Posted by CaptureStore when a timed reminder captured in the island is due. object = title (String)
    static let captureReminderDue = Notification.Name("notchBuddy.captureReminderDue")
}

/// Quick-capture inbox: every note, link, reminder and event typed in the island.
/// - Notes and links live only here (~/Library/Application Support/NotchBuddy/captures.json).
/// - Reminders / events are also written to Apple Reminders / Calendar; this list keeps a copy so the
///   inbox can show them. If EventKit access is off, the item is still saved here — nothing typed is lost.
@MainActor
final class CaptureStore: ObservableObject {
    static let shared = CaptureStore()

    @Published private(set) var items: [CaptureItem] = []

    private var nudgeWork: DispatchWorkItem?

    private static var fileURL: URL {
        HookServer.supportDir.appendingPathComponent("captures.json")
    }

    private init() {
        load()
        scheduleNextNudge()
    }

    // MARK: - Add

    func add(_ parsed: ParsedCapture, text: String) async -> CaptureOutcome {
        var item = CaptureItem(kind: parsed.kind, title: parsed.title, text: text,
                               url: parsed.url?.absoluteString, date: parsed.date,
                               endDate: parsed.endDate, hasTime: parsed.hasTime)
        if item.title.isEmpty && item.kind != .link { item.title = text }

        var message: String
        var warning = false
        let when = item.dateLabel.map { " · \($0)" } ?? ""

        switch item.kind {
        case .note:
            message = "Note saved"
        case .link:
            message = "Link saved"
        case .reminder:
            do {
                item.externalId = try await CalendarBridge.shared.createReminder(
                    title: item.title, due: item.date, hasTime: item.hasTime,
                    url: parsed.url, notes: nil)
                message = "Added to Reminders\(when)"
            } catch {
                message = "Saved here only — \(error.localizedDescription)"
                warning = true
            }
        case .event:
            do {
                item.externalId = try await CalendarBridge.shared.createEvent(
                    title: item.title, start: item.date ?? .now, end: item.endDate,
                    allDay: !item.hasTime, url: parsed.url, notes: nil)
                message = "Added to Calendar\(when)"
            } catch {
                message = "Saved here only — \(error.localizedDescription)"
                warning = true
            }
        }

        items.insert(item, at: 0)
        save()
        if item.kind == .reminder { scheduleNextNudge() }
        if item.kind == .link, let url = parsed.url { fetchTitle(for: item.id, url: url) }
        return CaptureOutcome(item: item, message: message, isWarning: warning)
    }

    // MARK: - Edit

    func toggleDone(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        if items[i].kind == .reminder, let ext = items[i].externalId {
            CalendarBridge.shared.setReminderCompleted(id: ext, items[i].done)
        }
        save()
        scheduleNextNudge()
    }

    /// Removes the item from the inbox only. Reminders / Calendar entries are left untouched on purpose:
    /// deleting from the user's calendar is not something a quick swipe should do.
    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
        scheduleNextNudge()
    }

    func clearDone() {
        items.removeAll { $0.done }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([CaptureItem].self, from: data) {
            items = decoded
        } else {
            // Unreadable file: keep a copy instead of overwriting the user's captures on next save
            let backup = Self.fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: Self.fileURL, to: backup)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: HookServer.supportDir, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Reveals captures.json in Finder (Settings → Quick capture).
    static func revealFile() {
        let url = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : HookServer.supportDir
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Link titles

    /// Fetches the <title> of a link the user pasted. Reads at most the first 64 KB, 6 s timeout.
    private func fetchTitle(for id: UUID, url: URL) {
        Task {
            var request = URLRequest(url: url, timeoutInterval: 6)
            request.setValue("Mozilla/5.0 (Macintosh) Coucou", forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            guard let response = try? await URLSession.shared.data(for: request) else { return }
            let data = response.0
            guard let html = String(data: data.prefix(65_536), encoding: .utf8)
                            ?? String(data: data.prefix(65_536), encoding: .isoLatin1),
                  let title = Self.extractTitle(from: html),
                  let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].linkTitle = title
            save()
        }
    }

    nonisolated static func extractTitle(from html: String) -> String? {
        let patterns = [
            #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#,
            #"<title[^>]*>([^<]+)</title>"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            let t = String(html[r])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return String(t.prefix(120)) }
        }
        return nil
    }

    // MARK: - Mochi nudge for due reminders

    /// One timer for the next due reminder (not a poll): keeps CPU at 0 while idle.
    /// Uses wall-clock time so it still fires on time after the Mac sleeps.
    private func scheduleNextNudge() {
        nudgeWork?.cancel()
        nudgeWork = nil
        let now = Date.now
        guard let next = items
            .filter({ $0.kind == .reminder && !$0.done && $0.hasTime })
            .compactMap({ item in item.date.map { (item, $0) } })
            .filter({ $0.1 > now })
            .min(by: { $0.1 < $1.1 }) else { return }

        let (item, due) = next
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.items.contains(where: { $0.id == item.id && !$0.done }) else { return }
            NotificationCenter.default.post(name: .captureReminderDue, object: item.title)
            self.scheduleNextNudge()
        }
        nudgeWork = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + due.timeIntervalSince(now), execute: work)
    }
}
