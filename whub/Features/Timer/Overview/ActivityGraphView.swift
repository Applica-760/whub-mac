import Charts
import SwiftData
import SwiftUI
import WhubCore

struct ActivityGraphView: View {
    @Environment(\.isRetainedPageActive) private var isActive
    @Query(sort: \ActivityRecord.startedAt) private var records: [ActivityRecord]
    @Query(sort: \ActivityCategory.name) private var categories: [ActivityCategory]
    @State private var weekOffset = 0
    @State private var excludedCategories: Set<UUID> = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 60, paused: !isActive)) { timeline in
            let calendar = Calendar.current
            let start = calendar.date(byAdding: .day, value: weekOffset * 7,
                                      to: activityWeekStart(for: timeline.date, calendar: calendar))!
            let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
            let totals = activityWeekTotals(records: records, weekStart: start,
                                            now: timeline.date, calendar: calendar)
            let selected = categories.filter { !excludedCategories.contains($0.id) }
            let labels = days.map { $0.formatted(.dateTime.month().day().weekday(.abbreviated)) }
            let total = selected.reduce(0.0) { $0 + (totals[$1.id]?.reduce(0, +) ?? 0) }

            WidgetFrame {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Weekly Activity").font(.headline)
                        Spacer()
                        Button("Previous week", systemImage: "chevron.left") { weekOffset -= 1 }
                            .labelStyle(.iconOnly)
                            .help("Previous week")
                        Text("\(days[0].formatted(date: .abbreviated, time: .omitted)) – \(days[6].formatted(date: .abbreviated, time: .omitted))")
                            .monospacedDigit()
                        Button("Next week", systemImage: "chevron.right") { weekOffset += 1 }
                            .labelStyle(.iconOnly)
                            .help("Next week")
                            .disabled(weekOffset == 0)
                        Button("This week") { weekOffset = 0 }
                            .disabled(weekOffset == 0)
                    }

                    HStack(alignment: .top, spacing: 20) {
                        Chart {
                            ForEach(0..<7, id: \.self) { day in
                                ForEach(selected) { category in
                                    let seconds = totals[category.id]?[day] ?? 0
                                    BarMark(
                                        x: .value("Day", labels[day]),
                                        y: .value("Hours", seconds / 3600),
                                        stacking: .standard
                                    )
                                    .foregroundStyle(by: .value("Activity", category.id.uuidString))
                                    .accessibilityLabel("\(labels[day]), \(category.name)")
                                    .accessibilityValue(activityDuration(seconds))
                                }
                            }
                        }
                        .chartXScale(domain: labels)
                        .chartYScale(domain: 0...max(1, (0..<7).map { day in
                            selected.reduce(0.0) { $0 + (totals[$1.id]?[day] ?? 0) } / 3600
                        }.max() ?? 0))
                        .chartYAxisLabel("Hours")
                        .chartForegroundStyleScale(domain: categories.map { $0.id.uuidString },
                                                   range: categories.map(\.displayColor))
                        .chartLegend(.hidden)
                        .frame(height: 240)
                        .overlay {
                            if total == 0 {
                                Text(selected.isEmpty ? "Select activities" : "No activity records")
                                    .foregroundStyle(.secondary)
                                    .allowsHitTesting(false)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Selected total").font(.subheadline)
                            Text(activityDuration(total))
                                .font(.title2.monospacedDigit())
                            ScrollView {
                                VStack(spacing: 10) {
                                    ForEach(categories) { category in
                                        HStack(spacing: 6) {
                                            Toggle(isOn: Binding(
                                                get: { !excludedCategories.contains(category.id) },
                                                set: { included in
                                                    if included {
                                                        excludedCategories.remove(category.id)
                                                    } else {
                                                        excludedCategories.insert(category.id)
                                                    }
                                                }
                                            )) {
                                                HStack(spacing: 6) {
                                                    Circle().fill(category.displayColor)
                                                        .frame(width: 8, height: 8)
                                                        .accessibilityHidden(true)
                                                    Text(category.name).lineLimit(1)
                                                        .help(category.name)
                                                }
                                            }
                                            .toggleStyle(.checkbox)
                                            Spacer(minLength: 4)
                                            Text(activityDuration(totals[category.id]?.reduce(0, +) ?? 0))
                                                .monospacedDigit()
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: 240)
                    }
                    .frame(height: 240)
                }
                .padding()
            }
        }
    }
}

private func activityDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(.time(pattern: .hourMinute))
}

private func activityWeekStart(for date: Date, calendar: Calendar) -> Date {
    var calendar = calendar
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar.dateInterval(of: .weekOfYear, for: date)!.start
}

@MainActor
private func activityWeekTotals(
    records: [ActivityRecord], weekStart: Date, now: Date, calendar: Calendar
) -> [UUID: [TimeInterval]] {
    let boundaries = (0...7).map { calendar.date(byAdding: .day, value: $0, to: weekStart)! }
    var totals: [UUID: [TimeInterval]] = [:]
    for record in records {
        let end = min(record.endedAt ?? now, now)
        for day in 0..<7 {
            let from = max(record.startedAt, boundaries[day])
            let to = min(end, boundaries[day + 1])
            if from < to {
                totals[record.category.id, default: Array(repeating: 0, count: 7)][day]
                    += to.timeIntervalSince(from)
            }
        }
    }
    return totals
}
