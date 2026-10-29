import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var store: TweakStore
    @State private var shareItem: ShareItem? = nil

    var body: some View {
        List {
            if store.records.isEmpty {
                Text("还没有生成过插件，去生成页做第一个。")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.records) { record in
                RecordRow(record: record, shareItem: $shareItem)
            }
            .onDelete { offsets in
                for index in offsets { store.delete(store.records[index]) }
            }
        }
        .navigationTitle("历史")
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }
}

private struct RecordRow: View {
    @EnvironmentObject var store: TweakStore
    let record: TweakRecord
    @Binding var shareItem: ShareItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.displayName).font(.headline)
            let slugText = record.input.slug.isEmpty ? record.input.name.lowercased() : record.input.slug
            Text(slugText + " · " + record.createdAt.formatted(date: .numeric, time: .shortened))
                .font(.footnote).foregroundStyle(.secondary)
            Text("状态：" + record.buildStatus)
                .font(.footnote).foregroundStyle(.secondary)
            if let repo = record.repoFullName {
                Text(repo).font(.footnote).foregroundStyle(.secondary)
            }
            if !record.problems.isEmpty {
                Text("检查提醒：" + record.problems.joined(separator: "；"))
                    .font(.footnote).foregroundStyle(.orange)
            }
            HStack(spacing: 14) {
                Button("分享工程") { shareItem = ShareItem(url: store.zipURL(record)) }
                if let deb = store.debURL(record) {
                    Button("分享 deb") { shareItem = ShareItem(url: deb) }
                } else if record.repoFullName != nil {
                    Button("刷新状态") { Task { await store.refreshStatus(record: record) } }
                    Button("重新推送") { Task { await store.uploadAndBuild(record: record) } }
                } else {
                    Button("送去打成品") { Task { await store.uploadAndBuild(record: record) } }
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }
}
