import SwiftUI

#if os(iOS)
    struct ToolsView: View {
        var body: some View {
            NavigationStack {
                Form {
                    Section("IPA Installation") {
                        NavigationLink {
                            ImportIPAView(embedded: true)
                        } label: {
                            Label("Import & Install IPA", systemImage: "square.and.arrow.down")
                        }
                        NavigationLink {
                            InstallationSettingsView()
                        } label: {
                            Label("Installation Settings", systemImage: "checkmark.shield")
                        }
                    }
                    Section("UnfairPlay") {
                        NavigationLink {
                            UnfairPlayModelsView()
                        } label: {
                            Label("FairPlay Models", systemImage: "key.horizontal")
                        }
                        NavigationLink {
                            UnfairPlaySourceView()
                        } label: {
                            Label("Process Downloaded IPA", systemImage: "lock.open")
                        }
                        NavigationLink {
                            ProcessedIPAList()
                        } label: {
                            Label("Processed IPAs", systemImage: "archivebox")
                        }
                    }
                }
                .formStyle(.grouped)
                .navigationTitle("Tools")
            }
        }
    }

    private struct InstallationSettingsView: View {
        @AppStorage(InstallationHost.preferenceKey) private var host = InstallationHost.legacy
        @Environment(\.openURL) private var openURL
        @State private var preparing = false
        @State private var replacing = false
        @State private var error: String?

        var body: some View {
            Form {
                Section {
                    Picker("Installation Domain", selection: $host) {
                        ForEach(InstallationHost.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .disabled(preparing)
                } footer: {
                    if host == .offline {
                        Text("asspp.localhost uses a certificate created on this device and works without external DNS.")
                    } else {
                        Text("Use the existing Asspp certificate profile for app.localhost.qaq.wiki.")
                    }
                }
                Section {
                    Button("Install Certificate") { setup() }.disabled(preparing)
                    if preparing { ProgressView() }
                    if host == .offline {
                        Button("Replace Offline Certificate", role: .destructive) { replacing = true }
                            .disabled(preparing)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                } header: {
                    Text("Certificate Trust")
                } footer: {
                    Text("Install the profile in Settings > General > VPN & Device Management, then enable full trust for that Asspp CA under General > About > Certificate Trust Settings.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Installation Settings")
            .confirmationDialog("Replace Offline Certificate?", isPresented: $replacing, titleVisibility: .visible) {
                Button("Replace Offline Certificate", role: .destructive) { setup(replace: true) }
            } message: {
                Text("Remove the previous offline profile and enable full trust for the new one after installing it.")
            }
        }

        private func setup(replace: Bool = false) {
            let selected = host
            preparing = true
            error = nil
            Task {
                defer { preparing = false }
                do {
                    if replace {
                        try await Task.detached { _ = try OfflineInstallationIdentity.load(replace: true) }.value
                    }
                    openURL(try await Installer.certificateURL(for: selected))
                } catch {
                    self.error = String(localized: "The certificate profile could not be prepared. Replace the offline certificate if it expired.")
                }
            }
        }
    }

    private struct UnfairPlaySourceView: View {
        @State private var downloads = Downloads.this

        var body: some View {
            List(downloads.manifests.filter(\.completed)) { manifest in
                NavigationLink {
                    Form {
                        ArchivePreviewView(archive: manifest.displayPackage)
                        UnfairPlaySection(inputURL: manifest.targetLocation, package: manifest.displayPackage)
                    }
                    .navigationTitle(manifest.package.software.name)
                } label: {
                    ArchivePreviewView(archive: manifest.displayPackage)
                }
            }
            .overlay {
                if !downloads.manifests.contains(where: \.completed) {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
                }
            }
            .navigationTitle("Process Downloaded IPA")
        }
    }
#endif

struct ProcessedIPAList: View {
    @State private var store = UnfairPlayArtifactStore.shared

    var body: some View {
        Form {
            if store.items.isEmpty {
                ContentUnavailableView("No Processed IPAs", systemImage: "archivebox")
            } else {
                Section {
                    ForEach(store.items) { artifact in
                        NavigationLink {
                            UnfairPlayResultView(artifact: artifact)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(artifact.package.software.name)
                                Text(artifact.title).font(.caption).foregroundStyle(.secondary)
                                Text("\(artifact.package.software.version) · \(ByteCountFormatter.string(fromByteCount: artifact.size, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Storage used: \(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Processed IPAs")
    }
}
