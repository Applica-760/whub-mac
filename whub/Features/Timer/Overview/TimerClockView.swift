import SwiftData
import SwiftUI
import WhubCore

struct TimerClockView: View {
    @Query(sort: \ActivityRecord.startedAt) private var records: [ActivityRecord]
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var editingRecord: ActivityRecord?
    @State private var newRecordStart = Date.now
    @State private var showsRecordForm = false

    private static let dateFormat = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits).\(month: .twoDigits).\(day: .twoDigits)",
        timeZone: .current, calendar: Calendar(identifier: .gregorian)
    )

    var body: some View {
        WidgetFrame {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(spacing: 12) {
                    Text(day, format: Self.dateFormat)
                        .font(.headline)
                    HStack(spacing: 12) {
                        preview(offset: -1, now: timeline.date)
                        Button("Previous day", systemImage: "chevron.left") { moveDay(-1) }
                            .help("Previous day")
                        ActivityClock(day: day, records: records, now: timeline.date, size: 220) {
                            editingRecord = $0
                            showsRecordForm = true
                        } onAdd: { start in
                            addRecord(startingAt: start)
                        }
                        Button("Next day", systemImage: "chevron.right") { moveDay(1) }
                            .disabled(Calendar.current.isDate(day, inSameDayAs: timeline.date))
                            .help("Next day")
                        preview(offset: 1, now: timeline.date)
                    }
                    .labelStyle(.iconOnly)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showsRecordForm) {
            ActivityRecordFormView(record: editingRecord, startedAt: newRecordStart)
        }
    }

    private func preview(offset: Int, now: Date) -> some View {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: day)!
        return VStack(spacing: 8) {
            Text(date, format: Self.dateFormat)
                .font(.caption)
            ActivityClock(day: date, records: records, now: now, size: 80) {
                editingRecord = $0
                showsRecordForm = true
            } onAdd: { start in
                addRecord(startingAt: start)
            }
        }
    }

    private func addRecord(startingAt start: Date) {
        editingRecord = nil
        newRecordStart = start
        showsRecordForm = true
    }

    private func moveDay(_ offset: Int) {
        day = Calendar.current.date(byAdding: .day, value: offset, to: day)!
    }
}

private struct ActivityClock: View {
    let day: Date
    let records: [ActivityRecord]
    let now: Date
    let size: CGFloat
    let onEdit: (ActivityRecord) -> Void
    let onAdd: (Date) -> Void

    var body: some View {
        ZStack {
            Circle().fill(.secondary.opacity(0.1))
                .allowsHitTesting(false)
            ring(period: 0)
            ring(period: 1)
            Circle().strokeBorder(.secondary, lineWidth: 1)
                .allowsHitTesting(false)
            ForEach(1...12, id: \.self) { hour in
                if size > 100 || hour.isMultiple(of: 3) {
                    let angle = Double(hour) * .pi / 6
                    Text("\(hour)")
                        .font(.system(size: size > 100 ? 11 : 8).monospacedDigit())
                        .position(x: size / 2 + sin(angle) * size * 0.44,
                                  y: size / 2 - cos(angle) * size * 0.44)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            if Calendar.current.isDate(day, inSameDayAs: now) {
                let handLength = size * (0.65 + 0.105) / 2
                Rectangle()
                    .fill(.primary)
                    .frame(width: 2, height: handLength)
                    .offset(y: -handLength / 2)
                    .rotationEffect(.degrees(clockFraction(now) * 360))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            Circle().fill(.primary).frame(width: 4, height: 4)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(day.formatted(date: .abbreviated, time: .omitted)))
    }

    private func ring(period: Int) -> some View {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: day)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: midnight)!
        let start = period == 0 ? midnight : noon
        let end = period == 0 ? noon : calendar.date(byAdding: .day, value: 1, to: midnight)!
        let diameter = size * (period == 0 ? 0.37 : 0.65)
        let width = size * 0.105

        return ZStack {
            Circle().stroke(.secondary.opacity(0.18), lineWidth: width)
                .contentShape(Circle().stroke(style: StrokeStyle(lineWidth: width)))
                .onTapGesture(count: 2) {
                    let ends = records.compactMap { record -> Date? in
                        let from = max(start, record.startedAt)
                        let to = min(end, record.endedAt ?? now)
                        return from < to ? to : nil
                    }
                    onAdd(defaultRecordStart(periodStart: start, recordEnds: ends))
                }
            ForEach(records) { record in
                let from = max(start, record.startedAt)
                let to = min(end, record.endedAt ?? now)
                if from < to {
                    let arc = Circle()
                        .trim(from: clockFraction(from), to: to == end ? 1 : clockFraction(to))
                        .rotation(.degrees(-90))
                    Button {
                        onEdit(record)
                    } label: {
                        arc.stroke(record.category.displayColor, lineWidth: width)
                            .contentShape(arc.stroke(style: StrokeStyle(lineWidth: width)))
                    }
                        .buttonStyle(.plain)
                        .help("\(record.category.name): \(from.formatted(date: .omitted, time: .shortened))–\(to.formatted(date: .omitted, time: .shortened))")
                        .accessibilityLabel(Text("\(period == 0 ? "AM" : "PM"), \(record.category.name): \(from.formatted(date: .omitted, time: .shortened))–\(to.formatted(date: .omitted, time: .shortened))"))
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

private func defaultRecordStart(
    periodStart: Date,
    recordEnds: [Date],
    calendar: Calendar = .current
) -> Date {
    guard let lastEnd = recordEnds.max() else { return periodStart }
    return calendar.dateInterval(of: .hour, for: lastEnd)!.end
}

private func clockFraction(_ date: Date) -> Double {
    let time = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
    return Double((time.hour! % 12) * 3600 + time.minute! * 60 + time.second!) / (12 * 3600)
}
