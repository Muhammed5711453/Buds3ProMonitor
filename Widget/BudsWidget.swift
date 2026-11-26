import WidgetKit
import SwiftUI

private enum SharedBatteryStore {
    static let appGroupID = "group.com.buds3pro.monitor"
    static let leftKey = "buds_left_battery"
    static let rightKey = "buds_right_battery"
    static let caseKey = "buds_case_battery"
    static let leftChargingKey = "buds_left_charging"
    static let rightChargingKey = "buds_right_charging"
    static let caseChargingKey = "buds_case_charging"
    static let updatedAtKey = "buds_last_updated"

    static func load() -> BudsBatterySnapshot {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        let left = defaults.object(forKey: leftKey) as? Int
        let right = defaults.object(forKey: rightKey) as? Int
        let caseLevel = defaults.object(forKey: caseKey) as? Int
        let leftCharging = defaults.bool(forKey: leftChargingKey)
        let rightCharging = defaults.bool(forKey: rightChargingKey)
        let caseCharging = defaults.bool(forKey: caseChargingKey)
        let updatedAt = defaults.object(forKey: updatedAtKey) as? Date

        return BudsBatterySnapshot(
            leftBattery: left,
            rightBattery: right,
            caseBattery: caseLevel,
            isLeftCharging: leftCharging,
            isRightCharging: rightCharging,
            isCaseCharging: caseCharging,
            lastUpdated: updatedAt
        )
    }
}

struct BudsBatterySnapshot {
    let leftBattery: Int?
    let rightBattery: Int?
    let caseBattery: Int?
    let isLeftCharging: Bool
    let isRightCharging: Bool
    let isCaseCharging: Bool
    let lastUpdated: Date?
}

struct BudsEntry: TimelineEntry {
    let date: Date
    let snapshot: BudsBatterySnapshot
}

struct BudsTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudsEntry {
        BudsEntry(
            date: Date(),
            snapshot: BudsBatterySnapshot(
                leftBattery: 100,
                rightBattery: 100,
                caseBattery: 90,
                isLeftCharging: false,
                isRightCharging: false,
                isCaseCharging: false,
                lastUpdated: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BudsEntry) -> Void) {
        completion(BudsEntry(date: Date(), snapshot: SharedBatteryStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BudsEntry>) -> Void) {
        let entry = BudsEntry(date: Date(), snapshot: SharedBatteryStore.load())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

struct BudsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: BudsEntry

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.10, blue: 0.15), Color(red: 0.12, green: 0.15, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if family == .systemSmall {
                smallView
            } else {
                mediumView
            }
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "earbuds")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.cyan)
                Text("Buds3 Pro")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
                Spacer()
            }

            Spacer(minLength: 0)

            smallRow(label: "L", level: entry.snapshot.leftBattery, isCharging: entry.snapshot.isLeftCharging)
            smallRow(label: "R", level: entry.snapshot.rightBattery, isCharging: entry.snapshot.isRightCharging)
            smallRow(label: "K", level: entry.snapshot.caseBattery, isCharging: entry.snapshot.isCaseCharging)

            Spacer(minLength: 0)

            if let updated = entry.snapshot.lastUpdated {
                Text(updated, style: .time)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            } else {
                Text("Veri bekleniyor")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(14)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "earbuds")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.cyan)
                    Text("Galaxy Buds3 Pro")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                }

                Spacer()

                if let updated = entry.snapshot.lastUpdated {
                    Text(updated, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            HStack(spacing: 10) {
                mediumCell(title: "Sol", badge: "L", level: entry.snapshot.leftBattery, isCharging: entry.snapshot.isLeftCharging)
                mediumCell(title: "Sağ", badge: "R", level: entry.snapshot.rightBattery, isCharging: entry.snapshot.isRightCharging)
                mediumCell(title: "Kutu", badge: "K", level: entry.snapshot.caseBattery, isCharging: entry.snapshot.isCaseCharging)
            }
        }
        .padding(14)
    }

    private func smallRow(label: String, level: Int?, isCharging: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(color(for: level).opacity(0.9))
                .clipShape(Circle())

            Text(level.map { "%\($0)" } ?? "--")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()

            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundColor(.yellow)
            }

            Spacer()
        }
    }

    private func mediumCell(title: String, badge: String, level: Int?, isCharging: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color(for: level))
                    .clipShape(Capsule())

                Spacer()

                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }

            Text(level.map { "%\($0)" } ?? "--")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(level == nil ? .white.opacity(0.5) : color(for: level))
                .monospacedDigit()

            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func color(for level: Int?) -> Color {
        guard let value = level else { return .gray }
        if value > 50 { return .green }
        if value >= 20 { return .orange }
        return .red
    }
}

@main
struct BudsWidget: Widget {
    let kind: String = "BudsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BudsTimelineProvider()) { entry in
            BudsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Buds3 Pro Pil")
        .description("Sol, sağ kulaklık ve şarj kutusu pil yüzdelerini gösterir.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
