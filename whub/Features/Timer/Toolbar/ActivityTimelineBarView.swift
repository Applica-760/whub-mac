import SwiftData
import SwiftUI
import WhubCore

struct ActivityTimelineBarView: View {
    @Query(sort: \ActivityRecord.startedAt) private var records: [ActivityRecord]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let calendar = Calendar.current
            let period = activityTimelinePeriod(for: timeline.date, calendar: calendar)
            let firstHour = calendar.component(.hour, from: period.start)
            HStack(spacing: 4) {
                Text(firstHour < 12 ? "AM" : "PM")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                Canvas { context, size in
                    let width = max(0, size.width - 16)
                    let track = CGRect(x: 8, y: 12, width: width, height: 8)
                    context.fill(Path(track), with: .color(.secondary.opacity(0.12)))

                    for record in records {
                        if let range = activityTimelineRange(
                            startedAt: record.startedAt, endedAt: record.endedAt,
                            now: timeline.date, period: period
                        ) {
                            let rect = CGRect(x: 8 + range.lowerBound * width, y: 12,
                                              width: (range.upperBound - range.lowerBound) * width,
                                              height: 8)
                            context.fill(Path(rect), with: .color(record.category.displayColor))
                        }
                    }

                    for hour in 0...6 {
                        let date = hour == 6 ? period.end : calendar.date(
                            bySettingHour: firstHour + hour, minute: 0, second: 0, of: period.start
                        )!
                        let x = 8 + date.timeIntervalSince(period.start) / period.duration * width
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: 12))
                        tick.addLine(to: CGPoint(x: x, y: hour.isMultiple(of: 2) ? 20 : 16))
                        context.stroke(tick, with: .color(.primary.opacity(0.5)), lineWidth: 0.5)
                        if hour.isMultiple(of: 2) {
                            context.draw(
                                Text(String(format: "%02d", firstHour + hour))
                                    .font(.system(size: 8).monospacedDigit())
                                    .foregroundStyle(.secondary),
                                at: CGPoint(x: x, y: 1), anchor: .top
                            )
                        }
                    }

                    let x = 8 + timeline.date.timeIntervalSince(period.start) / period.duration * width
                    var cursor = Path()
                    cursor.move(to: CGPoint(x: x, y: 10))
                    cursor.addLine(to: CGPoint(x: x, y: 22))
                    context.stroke(cursor, with: .color(.primary), lineWidth: 1)
                }
            }
            .help("\(period.start.formatted(date: .omitted, time: .shortened))–\(period.end.formatted(date: .omitted, time: .shortened)) · \(records.first { $0.endedAt == nil }?.category.name ?? "Stopped")")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Activity timeline, \(firstHour)–\(firstHour + 6)")
            .accessibilityValue(records.first { $0.endedAt == nil }?.category.name ?? "Stopped")
        }
        .frame(width: 180, height: 23)
    }
}

private func activityTimelinePeriod(for date: Date, calendar: Calendar = .current) -> DateInterval {
    let midnight = calendar.startOfDay(for: date)
    let hour = calendar.component(.hour, from: date) / 6 * 6
    let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: midnight)!
    let end = hour == 18 ? calendar.date(byAdding: .day, value: 1, to: midnight)!
        : calendar.date(bySettingHour: hour + 6, minute: 0, second: 0, of: midnight)!
    return DateInterval(start: start, end: end)
}

private func activityTimelineRange(
    startedAt: Date, endedAt: Date?, now: Date, period: DateInterval
) -> Range<Double>? {
    let from = max(startedAt, period.start)
    let to = min(min(endedAt ?? now, now), period.end)
    guard from < to else { return nil }
    let lower = from.timeIntervalSince(period.start) / period.duration
    let upper = to.timeIntervalSince(period.start) / period.duration
    return lower..<upper
}
