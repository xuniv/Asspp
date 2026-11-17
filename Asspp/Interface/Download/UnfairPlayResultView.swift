import SwiftUI
#if os(macOS)
    import AppKit
#endif

@MainActor
struct UnfairPlayResultView: View {
    let artifact: UnfairPlayArtifact
    @State private var store = UnfairPlayArtifactStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text(artifact.package.software.name).font(.headline)
                Text(artifact.package.software.bundleID).font(.caption)
                Text(ByteCountFormatter.string(fromByteCount: artifact.size, countStyle: .file))
                UnfairPlayReportView(report: artifact.report, operation: artifact.operation)
            }
            Section {
                IPAShareRow(url: artifact.url)
            } header: {
                Text("Control")
            } footer: {
                if artifact.operation == .decrypt {
                    Text("Decrypted IPAs require re-signing before installation. Asspp does not re-sign this copy.")
                } else if artifact.operation == .convertIPAMacOS {
                    Text("This private compatibility output is intended for a compatible macOS installer.")
                } else {
                    Text("Removing license data does not decrypt or re-sign an IPA.")
                }
            }
            Section {
                NavigationLink("Content Viewer") { FileListView(packageURL: artifact.url) }
                #if os(macOS)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }
                #endif
                Button("Delete Processed Copy", role: .destructive) { store.remove(artifact); dismiss() }
            } footer: {
                Text("Processed copies are removed after 24 hours or when Asspp restarts. Deleting this copy does not change the original IPA or saved models.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(artifact.title)
    }
}
