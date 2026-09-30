import SwiftUI

// MARK: - Capture (one field: note / link / reminder / event)

struct CaptureView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = CaptureStore.shared
    @State private var text = ""
    @State private var manualKind: CaptureKind? = nil
    @State private var feedback: CaptureOutcome? = nil
    @State private var saving = false
    @FocusState private var focused: Bool

    private var parsed: ParsedCapture? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return CaptureParser.parse(t, forcing: manualKind)
    }

    private var activeKind: CaptureKind? { parsed?.kind ?? manualKind }

    private var openCount: Int { store.items.filter { !$0.done }.count }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: wash)

            VStack(alignment: .leading, spacing: 7) {
                // Kind chips (auto-detected one lit; click to force) + live preview
                HStack(spacing: 5) {
                    ForEach(CaptureKind.allCases, id: \.self) { kind in
                        CaptureKindChip(kind: kind, isOn: activeKind == kind, isPinned: manualKind == kind) {
                            manualKind = (manualKind == kind) ? nil : kind
                            focused = true
                        }
                    }
                    Spacer(minLength: 6)
                    if let p = parsed, let label = previewLabel(p) {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#9398A1"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                // Field
                HStack(spacing: 8) {
                    TextField("Note, link, reminder or event…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit(submit)
                        .onExitCommand { NotificationCenter.default.post(name: .islandCollapse, object: nil) }

                    Button(action: submit) {
                        Image(systemName: saving ? "ellipsis" : "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(parsed == nil || saving)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .simultaneousGesture(TapGesture().onEnded { focused = true })

                // Feedback / hint + inbox link
                HStack(spacing: 5) {
                    if let f = feedback {
                        Image(systemName: f.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(Color(hex: f.isWarning ? "#F5A524" : "#34D399"))
                        Text(f.message)
                            .foregroundColor(Color(hex: "#B0B5BE"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("Try \u{201C}call Sam tomorrow 3pm\u{201D} or paste a link")
                            .foregroundColor(Color(hex: "#6B7079"))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .inbox }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tray")
                            Text(openCount > 0 ? "Inbox \(openCount)" : "Inbox")
                        }
                        .foregroundColor(Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 11))
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
        }
        .onChange(of: state.view) { _, v in
            if v == .capture { focused = true }
        }
        .onChange(of: text) { _, new in
            state.lastActivity = .now
            if !new.isEmpty { feedback = nil }
        }
    }

    private var wash: CardBackground<EmptyView>.Wash? {
        switch activeKind {
        case .note:     return .pink
        case .link:     return .cyan
        case .reminder: return .amber
        case .event:    return .green
        case nil:       return .soft
        }
    }

    private func previewLabel(_ p: ParsedCapture) -> String? {
        switch p.kind {
        case .note:
            return nil
        case .link:
            return p.url?.host ?? "No link found yet"
        case .reminder, .event:
            let title = p.title.isEmpty ? p.kind.label : p.title
            guard let date = p.date else { return "\(title) · no date" }
            let when = CaptureDateFormat.label(start: date, end: p.endDate, hasTime: p.hasTime)
            return "\(title) · \(when)"
        }
    }

    private func submit() {
        guard let p = parsed, !saving else { return }
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        state.stateOverride = .thinking
        Task {
            let outcome = await CaptureStore.shared.add(p, text: original)
            state.stateOverride = nil
            saving = false
            feedback = outcome
            text = ""
            manualKind = nil
            state.lastActivity = .now
            SoundEngine.shared.play(outcome.isWarning ? "error" : "send")
            NotificationCenter.default.post(name: .triggerEmote,
                                            object: outcome.isWarning ? BotEmote.surprised : BotEmote.happy)
            focused = true
        }
    }
}

struct CaptureKindChip: View {
    let kind: CaptureKind
    let isOn: Bool
    let isPinned: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: kind.icon).font(.system(size: 9.5, weight: .semibold))
                Text(kind.label).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isOn ? Color(hex: "#0B0C0E") : Color(hex: hovered ? "#B0B5BE" : "#8E939C"))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(isOn ? Color(hex: kind.color) : Color.white.opacity(hovered ? 0.09 : 0.05))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(isPinned ? 0.7 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(isPinned ? "Forced — click again for auto-detect" : "Save as \(kind.label.lowercased())")
    }
}

// MARK: - Inbox (recent captures + today's agenda)

struct InboxView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = CaptureStore.shared
    @State private var filter: CaptureKind? = nil
    @State private var agenda: [CalendarBridge.AgendaEntry] = []

    private var visible: [CaptureItem] {
        let base = store.items.filter { filter == nil || $0.kind == filter }
        // Open items first (newest first), done items at the bottom
        return base.filter { !$0.done } + base.filter { $0.done }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)

            VStack(alignment: .leading, spacing: 8) {
                // Filters + actions
                HStack(spacing: 5) {
                    InboxFilterChip(label: "All", icon: nil, color: "#F5F6F8", isOn: filter == nil) { filter = nil }
                    ForEach(CaptureKind.allCases, id: \.self) { kind in
                        InboxFilterChip(label: kind.label, icon: kind.icon, color: kind.color, isOn: filter == kind) {
                            filter = (filter == kind) ? nil : kind
                        }
                    }
                    Spacer(minLength: 6)
                    if store.items.contains(where: { $0.done }) {
                        Button("Clear done") { withAnimation { store.clearDone() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .capture }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                            .frame(width: 20, height: 20)
                            .background(Color(hex: "#F5F6F8"))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("New capture")
                }

                if !agenda.isEmpty && (filter == nil || filter == .event) {
                    AgendaStrip(entries: agenda)
                }

                if visible.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(filter == nil ? "Nothing captured yet." : "No \(filter!.label.lowercased())s yet.")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Open the capture field, type anything, press Return.")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(visible) { item in
                                InboxRow(item: item)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: visible)
                    }
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
        }
        .padding(.bottom, 10)
        .onChange(of: state.view) { _, v in
            if v == .inbox { agenda = CalendarBridge.shared.todayAgenda() }
        }
    }
}

struct InboxFilterChip: View {
    let label: String
    let icon: String?
    let color: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)) }
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isOn ? Color(hex: "#0B0C0E") : Color(hex: "#8E939C"))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(isOn ? Color(hex: color) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct InboxRow: View {
    let item: CaptureItem
    @State private var hovered = false
    @State private var copied = false

    private var subtitle: String? {
        switch item.kind {
        case .link:
            let host = item.url.flatMap { URL(string: $0)?.host }
            return [host, item.linkTitle != nil && !item.title.isEmpty ? item.title : nil]
                .compactMap { $0 }.joined(separator: " · ")
        case .reminder, .event:
            var parts: [String] = []
            if let d = item.dateLabel { parts.append(d) }
            parts.append(item.externalId != nil ? (item.kind == .reminder ? "Reminders" : "Calendar") : "Only here")
            return parts.joined(separator: " · ")
        case .note:
            return item.createdAt.formatted(.relative(presentation: .named))
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if item.kind == .reminder {
                Button { withAnimation { CaptureStore.shared.toggleDone(item.id) } } label: {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: item.done ? "#34D399" : "#6B7079"))
                }
                .buttonStyle(.plain)
                .frame(width: 16)
            } else {
                Image(systemName: item.kind.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: item.kind.color))
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Color(hex: item.done ? "#6B7079" : "#F1F2F4"))
                    .strikethrough(item.done)
                    .lineLimit(item.kind == .note ? 2 : 1)
                    .truncationMode(.tail)
                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: "#6E737C"))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if hovered {
                HStack(spacing: 10) {
                    Button(action: primaryAction) {
                        Image(systemName: primaryIcon)
                    }
                    .buttonStyle(.plain)
                    .help(primaryHelp)

                    Button { withAnimation { CaptureStore.shared.remove(item.id) } } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help(item.externalId != nil ? "Remove from inbox (stays in \(item.kind == .reminder ? "Reminders" : "Calendar"))" : "Delete")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "#8E939C"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(hovered ? 0.08 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
        .onTapGesture(count: 2) { primaryAction() }
    }

    private var primaryIcon: String {
        switch item.kind {
        case .link:     return "arrow.up.right"
        case .note:     return copied ? "checkmark" : "doc.on.doc"
        case .reminder, .event: return "arrow.up.forward.app"
        }
    }

    private var primaryHelp: String {
        switch item.kind {
        case .link:     return "Open link"
        case .note:     return "Copy"
        case .reminder: return "Open Reminders"
        case .event:    return "Open Calendar"
        }
    }

    private func primaryAction() {
        switch item.kind {
        case .link:
            if let s = item.url, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case .note:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
            SoundEngine.shared.play("tick")
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        case .reminder, .event:
            CalendarBridge.shared.openApp(for: item.kind)
        }
    }
}

struct AgendaStrip: View {
    let entries: [CalendarBridge.AgendaEntry]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Text("Today")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#6B7079"))
                ForEach(entries) { e in
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: CaptureKind.event.color)).frame(width: 5, height: 5)
                        Text(e.allDay ? "All day" : e.start.formatted(date: .omitted, time: .shortened))
                            .foregroundColor(Color(hex: "#8E939C"))
                        Text(e.title)
                            .foregroundColor(Color(hex: "#D5D8DD"))
                            .lineLimit(1)
                    }
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
                }
            }
        }
    }
}
