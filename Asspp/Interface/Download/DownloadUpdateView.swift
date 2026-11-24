import SwiftUI

struct DownloadUpdateView: View {
    let manifest: PackageManifest
    let updates: DownloadUpdates
    @State private var artifacts = UnfairPlayArtifactStore.shared
    @State private var result: DownloadUpdates.Result?
    @State private var checking = true
    @State private var downloading = false
    @State private var transfer: PackageManifest?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var newer: Bool {
        guard let result else { return false }
        return DownloadVersion.compare(result.package.software.version, manifest.version) == .orderedDescending
    }

    private var country: String {
        guard let code = manifest.storefront else { return String(localized: "Unknown") }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }

    var body: some View {
        Form {
            Section {
                ArchivePreviewView(archive: manifest.displayPackage)
                LabeledContent("Downloaded Version", value: manifest.version)
                LabeledContent("App Store Country", value: country)
                if let size = manifest.fileSize {
                    LabeledContent("IPA Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                let copies = artifacts.outputs(for: manifest.targetLocation).filter { $0.operation == .decrypt }
                let hasDecrypted = artifacts.hasDecryptedCopy(of: manifest.package, version: manifest.version)
                LabeledContent("Decrypted IPA") {
                    if hasDecrypted { Text("Available") } else { Text("None") }
                }
                if !copies.isEmpty {
                    let bytes = copies.reduce(0) { $0 + $1.size }
                    LabeledContent("Processed Copy Size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
            }
            Section {
                if checking { ProgressView("Checking for Updates…") }
                if let result {
                    LabeledContent("Latest Version", value: result.package.software.version)
                    if !newer { Text("No newer version is available.").foregroundStyle(.secondary) }
                    if newer, let notes = result.package.software.releaseNotes, !notes.isEmpty {
                        Text(notes).font(.subheadline)
                    }
                    if newer, transfer == nil {
                        Button("Download Latest", systemImage: "arrow.down.circle") {
                            Task { await download(result.package) }
                        }
                        .disabled(downloading || checking || updates.isRunning)
                    }
                }
                if downloading { ProgressView("Preparing Update…") }
                if let transfer {
                    ProgressView(value: transfer.state.percent)
                    Text(transfer.hint)
                    if [.failed, .paused].contains(transfer.state.status) {
                        Button("Download Latest", systemImage: "arrow.down.circle") {
                            if let result { Task { await download(result.package) } }
                        }
                        .disabled(downloading || updates.isRunning)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                    if result == nil {
                        Button("Retry") { Task { await check() } }
                            .disabled(checking)
                    }
                }
            } header: {
                Text("App Store Update")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Check for Updates")
        .toolbar { Button("Done") { dismiss() } }
        .task { await check() }
    }

    private func check() async {
        checking = true
        error = nil
        defer { checking = false }
        do { result = try await updates.check(manifest) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    private func download(_ package: AppStore.AppPackage) async {
        guard !downloading else { return }
        downloading = true
        error = nil
        defer { downloading = false }
        do { transfer = try await updates.downloadLatest(from: manifest, package: package) }
        catch { self.error = error.localizedDescription }
    }
}
