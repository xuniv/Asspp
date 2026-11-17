import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
    import AppKit
#endif

struct ImportIPAView: View {
    @State private var store = ImportedIPAStore.shared
    @State private var choosing = false
    @State private var busy = false
    @State private var error: String?
    #if os(iOS)
        @State private var installer: Installer?
    #else
        @State private var devices = DeviceManager()
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Choose IPA File") { choosing = true }.disabled(busy)
                    if busy { ProgressView("Importing IPA...") }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                } footer: {
                    Text("Import an IPA from ipatool or another tool without adding an Apple account. Files are kept temporarily and removed after 24 hours or when Asspp restarts. Total storage is limited to 8 GiB.")
                }
                #if os(macOS)
                    Section {
                        Picker("Device", selection: $devices.selectedDeviceID) {
                            Text("Select a Device").tag(String?.none)
                            ForEach(devices.devices) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Button("Refresh Devices") { Task { await devices.loadDevices() } }
                    }
                #endif
                ForEach(store.items) { item in
                    Section {
                        Text(item.package.software.name).font(.headline)
                        Text(item.package.software.bundleID).font(.caption).textSelection(.enabled)
                        Text(item.package.software.version)
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        #if os(iOS)
                            Button("Install") {
                                Task {
                                    do { error = nil; installer = try await Installer(archive: item.package, path: item.url) }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                            Button("Install via AirDrop") { AirDrop(items: [item.url]) }
                            IPAShareRow(url: item.url)
                        #else
                            Button("Install") {
                                guard let device = devices.selectedDevice else { return }
                                Task {
                                    if await devices.install(ipa: item.url, to: device) == false { error = String(localized: "Device installation failed. See Settings > Logs for details.") }
                                }
                            }.disabled(devices.selectedDevice == nil || devices.installingProcess != nil)
                            IPAShareRow(url: item.url)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        #endif
                        Button("Delete", role: .destructive) { store.remove(item) }
                    }
                    UnfairPlaySection(inputURL: item.url, package: item.package)
                }
                Section {
                    Text("The original IPA is preserved. Installation requires a valid signature and any required App Store license; importing does not resign or decrypt the app.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import IPA")
            .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { result in
                switch result {
                case let .success(url):
                    busy = true
                    Task {
                        defer { busy = false }
                        do { error = nil; try await store.add(url) }
                        catch { self.error = error.localizedDescription }
                    }
                case let .failure(error): self.error = error.localizedDescription
                }
            }
            .onAppear { store.cleanup() }
            #if os(iOS)
                .sheet(item: $installer) { installer?.destroy(); installer = nil } content: { InstallerView(installer: $0) }
            #else
                .task { await devices.loadDevices() }
            #endif
        }
    }
}
