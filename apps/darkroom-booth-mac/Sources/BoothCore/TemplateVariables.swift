import Foundation

/// `%Var%` substitution used by templates, email bodies and on-screen text in
/// the Windows app (CScriptHelper::ReplaceVarData / EdgReplaceVars).
/// Unknown variables are left in place so missing data stays visible.
public struct TemplateVariables: Sendable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    /// Standard date/event variables for a session (names from Eventlib XML 1389).
    public static func standard(eventName: String, eventDate: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> TemplateVariables {
        func format(_ template: String, _ date: Date) -> String {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = locale
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        let time24 = DateFormatter()
        time24.calendar = calendar
        time24.locale = Locale(identifier: "en_US_POSIX")
        time24.timeZone = calendar.timeZone
        time24.dateFormat = "HH:mm"
        return TemplateVariables([
            "Event": eventName,
            "EventName": eventName,
            "Event-Date": format("yMd", eventDate),
            "EventDate": format("yMd", eventDate),
            "Date": format("yMd", now),
            "ShortDate": format("yMd", now),
            "LongDate": format("yMMMMd", now),
            "DayOfWeek": format("EEEE", now),
            "Time": format("jmm", now),
            "Time24": time24.string(from: now),
        ])
    }

    public func replacing(in text: String) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "%" else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let nameStart = text.index(after: index)
            guard let close = text[nameStart...].firstIndex(of: "%") else {
                output.append(contentsOf: text[index...])
                break
            }
            let name = String(text[nameStart..<close])
            if name.isEmpty {
                // "%%" is a literal percent sign.
                output.append("%")
            } else if let value = lookup(name) {
                output.append(value)
            } else {
                output.append(contentsOf: text[index...close])
            }
            index = text.index(after: close)
        }
        return output
    }

    private func lookup(_ name: String) -> String? {
        if let exact = values[name] { return exact }
        let lowered = name.lowercased()
        return values.first { $0.key.lowercased() == lowered }?.value
    }
}
