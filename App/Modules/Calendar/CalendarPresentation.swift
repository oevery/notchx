import Foundation

enum CalendarPresentation {
    static func formatted(_ date: Date, template: String, locale: Locale = L10n.locale,
                          timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    static func timeRange(start: Date, end: Date, locale: Locale = L10n.locale, timeZone: TimeZone = .current) -> String {
        "\(formatted(start, template: "jmm", locale: locale, timeZone: timeZone)) - \(formatted(end, template: "jmm", locale: locale, timeZone: timeZone))"
    }
}
