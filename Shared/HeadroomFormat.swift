import Foundation

/// Number and date shaping shared by macOS, iOS, and the widget.
///
/// These run inside chart bodies, so the formatters are built once and held
/// rather than allocated per bar.
enum HeadroomFormat {
    /// "1.2k" / "3.4M". Chart axes and traffic counts, where the exact figure
    /// is not the point and the column is narrow.
    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter
    }()

    /// "2026-07-28" → "Tue". Falls back to the bare "MM-DD" tail so an
    /// unparseable date still labels its bar instead of blanking it.
    static func shortWeekday(isoDate: String) -> String {
        guard let date = isoDay.date(from: isoDate) else {
            return String(isoDate.suffix(5))
        }
        return weekday.string(from: date)
    }

    /// "Fri 31 Jul, 11:05" — a past event that needs naming to the minute.
    ///
    /// Localised rather than POSIX, unlike the chart formatters above: this one
    /// is read as a sentence rather than matched against a key, and the day
    /// order is the reader's own.
    private static let eventMoment: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return formatter
    }()

    static func eventMoment(_ date: Date) -> String {
        eventMoment.string(from: date)
    }
}
