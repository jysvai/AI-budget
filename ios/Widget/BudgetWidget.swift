import SwiftUI
import WidgetKit

struct BudgetEntry: TimelineEntry {
    let date: Date
    let snapshot: [String: Any]
    let error: String?
}
struct BudgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry {
        BudgetEntry(date: Date(), snapshot: ["remaining": 946310, "recommendedDaily": 67593], error: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (BudgetEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(1800))))
    }
    private func read() -> BudgetEntry {
        guard LedgerStore.sharedStorageAvailable else {
            return BudgetEntry(date: Date(), snapshot: [:], error: "모아를 열어 최신 장부를 확인하세요")
        }
        do { return BudgetEntry(date: Date(), snapshot: try LedgerStore().snapshot(), error: nil) }
        catch { return BudgetEntry(date: Date(), snapshot: [:], error: "앱에서 장부 상태를 확인해주세요.") }
    }
}
struct BudgetWidgetView: View {
    let entry: BudgetEntry
    @Environment(\.widgetFamily) var family
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "wallet.pass.fill").foregroundStyle(.teal)
                Text("모아").font(.caption.bold())
                Spacer()
                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            if let error = entry.error {
                Spacer()
                Text("장부는 안전하게 저장 중").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label("앱 열기", systemImage: "arrow.up.right").font(.caption.bold()).foregroundStyle(.teal)
            }
            else {
                Text("남은 생활비").font(.caption).foregroundStyle(.secondary)
                Text(won(entry.snapshot["remaining"])).font(.title2.bold()).foregroundStyle(.teal).minimumScaleFactor(0.6)
                Text("하루 권장 \(won(entry.snapshot["recommendedDaily"]))").font(.caption)
                if family == .systemMedium {
                    HStack {
                        Text("총지출 \(won(entry.snapshot["spent"]))")
                        if entry.snapshot["salaryConfirmed"] as? Bool != true { Text("예상 월급 기준").foregroundStyle(.orange) }
                    }.font(.caption2)
                }
                if let pending = entry.snapshot["pendingCount"] as? Int, pending > 0 { Text("미반영 검토 \(pending)건").font(.caption2).foregroundStyle(.orange) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.background, for: .widget)
            .widgetURL(URL(string: "aibudget://home"))
    }
}
@main struct BudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BudgetWidget", provider: BudgetProvider()) { BudgetWidgetView(entry: $0) }
            .configurationDisplayName("생활비 현황").description("남은 생활비와 하루 권장액을 확인하세요.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
