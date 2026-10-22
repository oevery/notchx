import Foundation

// Framework-free, immutable values are the only calendar data shared with the UI.
enum CalendarKind: Int, Sendable {
    case local = 0, calDAV, exchange, subscription, birthday
    case unknown = -1
}

struct CalendarDisplayOption: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let sourceID: String
    let sourceTitle: String
    let colorComponents: [Double]
    let type: CalendarKind
}

struct CalendarSourceGroup: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let calendars: [CalendarDisplayOption]
}

struct CalendarEventSnapshot: Sendable, Equatable {
    let eventIdentifier: String?
    let title: String?
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let calendar: CalendarDisplayOption
    var meetingURL: URL? = nil

    /// EventKit ranges are half-open: an event ending at midnight does not
    /// occupy the following day. Clip multi-day events to the visible range.
    func occurringDays(from rangeStart: Date, to rangeEnd: Date, calendar: Calendar) -> [Date] {
        if endDate == startDate, startDate >= rangeStart, startDate < rangeEnd {
            return [calendar.startOfDay(for: startDate)]
        }
        guard startDate < rangeEnd, endDate > rangeStart, endDate > startDate else { return [] }
        var day = calendar.startOfDay(for: max(startDate, rangeStart))
        let end = min(endDate, rangeEnd)
        var days: [Date] = []
        while day < end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return days
    }
}

struct CalendarActivity {
    let current: CalendarEventSnapshot?
    let next: CalendarEventSnapshot?
    init(events: [CalendarEventSnapshot], now: Date) {
        let timed = events.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        current = timed.first { $0.startDate <= now && $0.endDate > now }
        next = timed.first { $0.startDate > now }
    }
}

struct CalendarReminderLedger {
    private struct Key: Hashable {
        let id: String
        let calendarID: String
        let start: Date
    }
    private var delivered: [Key: Date] = [:]

    mutating func claim(_ event: CalendarEventSnapshot, now: Date) -> Bool {
        delivered = delivered.filter { $0.value > now }
        guard !event.isAllDay, event.startDate > now else { return false }
        let key = Key(id: event.eventIdentifier ?? event.title ?? "", calendarID: event.calendar.id, start: event.startDate)
        guard delivered[key] == nil else { return false }
        delivered[key] = event.endDate
        return true
    }
}

struct CalendarEventFilter: Sendable {
    // nil means all calendars; an empty set is an intentional empty selection.
    let enabledCalendarIDs: Set<String>?
    let hideBirthdays: Bool
    let hideHolidays: Bool
    let collapseDuplicates: Bool

    func visibleEvents(from events: [CalendarEventSnapshot]) -> [CalendarEventSnapshot] {
        let filtered = events.filter { event in
            let calendar = event.calendar
            if let enabledCalendarIDs, !enabledCalendarIDs.contains(calendar.id) { return false }
            if hideBirthdays, calendar.type == .birthday || calendar.title.localizedCaseInsensitiveContains("birthday") { return false }
            if hideHolidays, calendar.title.localizedCaseInsensitiveContains("holiday") || calendar.sourceTitle.localizedCaseInsensitiveContains("holiday") { return false }
            return true
        }
        var visible: [CalendarEventSnapshot] = []
        for event in filtered {
            if collapseDuplicates, visible.contains(where: { isDuplicate($0, event) }) { continue }
            visible.append(event)
        }
        return visible.sorted { $0.startDate < $1.startDate }
    }

    private func isDuplicate(_ lhs: CalendarEventSnapshot, _ rhs: CalendarEventSnapshot) -> Bool {
        guard normalized(lhs.title) == normalized(rhs.title),
              lhs.startDate == rhs.startDate,
              lhs.endDate == rhs.endDate,
              lhs.isAllDay == rhs.isAllDay else { return false }
        let left = normalized(lhs.location)
        let right = normalized(rhs.location)
        return left == right || left.isEmpty || right.isEmpty
    }

    private func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
