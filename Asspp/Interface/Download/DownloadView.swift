//
//  DownloadView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import SwiftUI

struct DownloadView: View {
    @State private var vm = Downloads.this
    @State private var artifacts = UnfairPlayArtifactStore.shared
    @State private var updates = DownloadUpdates()
    @State private var selected: PackageManifest?
    @State private var expanded: Set<String> = []

    private var groups: [DownloadGroup] {
        Dictionary(grouping: vm.manifests, by: DownloadUpdateKey.appKey)
            .map { key, manifests in
                DownloadGroup(id: key, versions: manifests.sorted { a, b in
                    let comparison = DownloadVersion.compare(a.version, b.version)
                    return comparison == .orderedSame ? a.creation > b.creation : comparison == .orderedDescending
                })
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.manifests.isEmpty, updates.batch == nil {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Search for an app or add a download link to get started.")
                    } actions: {
                        NavigationLink("Add Download") { AddDownloadView() }
                    }
                    .padding()
                } else {
                    Form {
                        if let batch = updates.batch { batchStatus(batch) }
                        Section {
                            ForEach(groups) { group in
                                if let newest = group.versions.first {
                                    row(newest)
                                    if group.versions.count > 1 {
                                        DisclosureGroup(isExpanded: expansion(for: group.id)) {
                                            ForEach(group.versions.dropFirst()) { row($0) }
                                        } label: {
                                            Text("More versions (\(group.versions.count - 1))")
                                                .font(.footnote)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("Downloads")
            .task {
                for manifest in vm.manifests where manifest.completed {
                    if Task.isCancelled { break }
                    await manifest.resolveDownloadedVersion()
                }
                vm.saveManifests()
            }
            .navigationDestination(for: PackageManifest.self) { PackageView(pkg: $0) }
            .sheet(item: $selected) { manifest in
                NavigationStack { DownloadUpdateView(manifest: manifest, updates: updates) }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("Check & Download All", systemImage: "arrow.down.circle") {
                            updates.startBatch(download: true)
                        }
                    } label: {
                        Label("Check All Updates", systemImage: "arrow.clockwise")
                    } primaryAction: {
                        updates.startBatch(download: false)
                    }
                    .disabled(updates.isRunning || !vm.manifests.contains(where: \.completed))
                    NavigationLink(destination: AddDownloadView()) {
                        Label("Add Download", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func row(_ manifest: PackageManifest) -> some View {
        PackageManifestRow(
            manifest: manifest,
            decrypted: artifacts.hasDecryptedCopy(of: manifest.package, version: manifest.version),
            updateAvailable: updates.available(for: manifest) != nil,
            check: { selected = manifest },
        )
    }

    private func expansion(for key: String) -> Binding<Bool> {
        Binding {
            expanded.contains(key)
        } set: { show in
            if show { expanded.insert(key) }
            else { expanded.remove(key) }
        }
    }

    private func batchStatus(_ batch: DownloadUpdates.Batch) -> some View {
        Section {
            if updates.isRunning {
                let part = updates.currentTransfer?.state.percent ?? 0
                ProgressView(value: Double(batch.finished) + part, total: Double(batch.total))
                if let transfer = updates.currentTransfer {
                    Text(transfer.package.software.name)
                        .font(.subheadline)
                    Text(transfer.hint).font(.caption).foregroundStyle(.secondary)
                }
                Button("Stop Batch", role: .cancel) { updates.cancelBatch() }
            } else {
                Button("Dismiss Update Summary") { updates.dismissBatch() }
            }
        } header: {
            if batch.canceled {
                Text("Update Check Stopped")
            } else if batch.downloadsUpdates {
                Text("Check & Download All")
            } else {
                Text("Check All Updates")
            }
        } footer: {
            VStack(alignment: .leading) {
                Text("Checked \(batch.finished) of \(batch.total) · Updates \(batch.found)")
                if batch.downloadsUpdates { Text("Downloaded \(batch.downloaded)") }
                if batch.failed > 0 { Text("Failed \(batch.failed). Check each app for details.") }
            }
        }
    }
}

private struct DownloadGroup: Identifiable {
    let id: String
    let versions: [PackageManifest]
    var lastActivity: Date { versions.map(\.creation).max() ?? .distantPast }
}

private struct PackageManifestRow: View {
    let manifest: PackageManifest
    let decrypted: Bool
    let updateAvailable: Bool
    let check: () -> Void
    @State private var vm = Downloads.this

    var body: some View {
        NavigationLink(value: manifest) {
            VStack(alignment: .leading, spacing: 8) {
                ArchivePreviewView(archive: manifest.displayPackage)
                if manifest.storefront != nil || decrypted || updateAvailable {
                    HStack(spacing: 6) {
                        if let country = manifest.storefront {
                            badge(Label { Text(country) } icon: { Image(systemName: "globe") }, color: .secondary)
                                .accessibilityLabel(Locale.current.localizedString(forRegionCode: country) ?? country)
                        }
                        if decrypted { badge(Label("Decrypted", systemImage: "lock.open"), color: .teal) }
                        if updateAvailable { badge(Label("Update", systemImage: "arrow.up.circle"), color: .accentColor) }
                    }
                    .lineLimit(1)
                }
                if !manifest.completed {
                    SimpleProgress(progress: manifest.state.percent)
                        .animation(.interactiveSpring, value: manifest.state.percent)
                }
                HStack {
                    Text(manifest.hint)
                    Spacer()
                    Text(manifest.creation.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            if manifest.completed {
                Button("Check for Updates", systemImage: "arrow.clockwise", action: check)
            }
            ForEach(vm.getAvailableActions(for: manifest), id: \.self) { action in
                let label = vm.getActionLabel(for: action)
                Button(role: label.isDestructive ? .destructive : .none) {
                    vm.performDownloadAction(for: manifest, action: action)
                } label: {
                    Label(label.title, systemImage: label.systemImage)
                }
            }
        }
    }

    private func badge(_ content: some View, color: Color) -> some View {
        content
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

extension PackageManifest {
    var hint: String {
        if let error = state.error {
            return error
        }
        return switch state.status {
        case .pending:
            String(localized: "Pending...")
        case .downloading:
            [
                String(Int(state.percent * 100)) + "%",
                state.speed.isEmpty ? "" : state.speed + "/s",
            ]
            .compactMap(\.self)
            .joined(separator: " ")
        case .paused:
            String(localized: "Paused")
        case .completed:
            String(localized: "Completed")
        case .failed:
            String(localized: "Failed")
        }
    }
}
