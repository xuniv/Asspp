import SwiftUI
#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

@MainActor
struct UnfairPlayResultView: View {
    let artifact: UnfairPlayArtifact
    @State private var store = UnfairPlayArtifactStore.shared
    @State private var error: String?
    #if os(iOS)
        @State private var exporting = false
    #endif
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
                #if os(iOS)
                    Button("Save to Files") { exporting = true }
                    FeatherOpenButton(url: artifact.url) {
                        error = String(localized: "No installed app can open this IPA. Install Feather or use Save to Files.")
                    }
                #endif
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
                Button("Delete Processed Copy", role: .destructive) {
                    do { try store.remove(artifact); dismiss() }
                    catch { self.error = String(localized: "The processed IPA could not be deleted.") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("Processed copies stay in Asspp until you delete them. Export a copy to keep it outside the app.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(artifact.title)
        #if os(iOS)
            .sheet(isPresented: $exporting) { IPAFileExporter(url: artifact.url) }
        #endif
    }
}

#if os(iOS)
    private struct IPAFileExporter: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        }

        func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    }

    private struct FeatherOpenButton: UIViewRepresentable {
        let url: URL
        let unavailable: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(String(localized: "Open in Feather"), for: .normal)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak button, weak coordinator = context.coordinator] _ in
                guard let button, let coordinator else { return }
                let controller = UIDocumentInteractionController(url: coordinator.url)
                controller.uti = "thewonderofyou.Feather.ipa"
                coordinator.controller = controller
                if !controller.presentOpenInMenu(from: button.bounds, in: button, animated: true) {
                    coordinator.unavailable?()
                }
            }, for: .touchUpInside)
            return button
        }

        func updateUIView(_ button: UIButton, context: Context) {
            context.coordinator.url = url
            context.coordinator.unavailable = unavailable
        }

        final class Coordinator {
            var url = URL(fileURLWithPath: "/")
            var unavailable: (() -> Void)?
            var controller: UIDocumentInteractionController?
        }
    }
#endif
