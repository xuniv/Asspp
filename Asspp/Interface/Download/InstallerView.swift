#if os(iOS)
    import SwiftUI
    import UIKit

    struct InstallerView: View {
        @State var installer: Installer
        @State private var checking = false
        @State private var error: String?
        @Environment(\.openURL) private var openURL

        private var status: String {
            switch installer.status {
            case .ready: String(localized: "Ready To Install")
            case .sendingManifest: String(localized: "Sending Manifest...")
            case .sendingPayload: String(localized: "Sending Payload...")
            case let .completed(result):
                switch result {
                case .success: String(localized: "Package sent to iOS. Check the Home Screen for installation progress.")
                case let .failure(error): error.localizedDescription
                }
            case let .broken(error): error.localizedDescription
            }
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        if checking { ProgressView("Checking certificate trust and local server...") }
                        else { Text(status) }
                        if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        Button("Retry Installation") { Task { await install() } }
                            .disabled(checking)
                    }
                    Section {
                        Button("Install Certificate") {
                            Task {
                                do { openURL(try await Installer.certificateURL()) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    } header: { Text("Certificate Trust") }
                        footer: { Text("Install the Asspp certificate profile in Settings > General > VPN & Device Management, then enable full trust for Asspp Local Installation CA in Settings > General > About > Certificate Trust Settings. Replace any older Asspp certificate profile first.") }
                    Section {
                        Text("Keep Asspp open while iOS downloads the package. A valid signature and the required App Store license are still needed.")
                    }
                }
                .navigationTitle("Install")
            }
            .task { await install() }
            .onDisappear { installer.destroy() }
        }

        @MainActor
        private func install() async {
            guard !checking else { return }
            checking = true
            error = nil
            defer { checking = false }
            do {
                try await installer.checkConnection()
                guard await UIApplication.shared.open(installer.iTunesLink) else { throw InstallationError.linkRejected }
            } catch { self.error = error.localizedDescription }
        }
    }
#endif
