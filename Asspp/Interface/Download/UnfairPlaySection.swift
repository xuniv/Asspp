import SwiftUI

struct IPAShareRow: View {
    let url: URL

    var body: some View {
        ShareLink(item: url) {
            Label("Share IPA", systemImage: "square.and.arrow.up")
        }
    }
}

@MainActor
struct UnfairPlaySection: View {
    let inputURL: URL
    let package: AppStore.AppPackage
    @State private var models = UnfairPlayModelStore.shared
    @State private var artifacts = UnfairPlayArtifactStore.shared
    @State private var session = UnfairPlaySession()

    var body: some View {
        Section {
            NavigationLink {
                UnfairPlayModelsView()
            } label: {
                Label("FairPlay Models", systemImage: "key.horizontal")
                Spacer()
                Text(models.selectedCount, format: .number).foregroundStyle(.secondary)
            }
            Button("Decrypt IPA") { perform(.decrypt) }
                .disabled(session.busy || models.selectedCount == 0 || models.importing)
            Button("Decrypt IPA (Strip Account Data)") { perform(.decrypt, stripped: true) }
                .disabled(session.busy || models.selectedCount == 0 || models.importing)
            Button("Verify IPA") { perform(.verify) }
                .disabled(session.busy || models.selectedCount == 0 || models.importing)
            Menu("More Operations") {
                Button("Inspect IPA") { perform(.doctor) }
                Button("Strip Account Data") { perform(.stripAccountData, stripped: true) }
                Button("Convert Encrypted IPA for macOS") { perform(.convertIPAMacOS) }
                    .disabled(models.importing)
            }
            .disabled(session.busy)
            if session.busy {
                ProgressView("Processing IPA…")
                Button("Cancel") { session.cancel() }
            }
            if let selectionError = models.selectionError { Text(selectionError).foregroundStyle(.red) }
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let report = session.report, let operation = session.operation {
                UnfairPlayReportView(report: report, operation: operation)
            }
            ForEach(artifacts.outputs(for: inputURL)) { item in
                NavigationLink {
                    UnfairPlayResultView(artifact: item)
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.title)
                        Text(item.createdAt, format: .dateTime.hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("UnfairPlay")
        } footer: {
            Text("Import private .bin models recovered on your Mac. Matching models are selected automatically for each IPA. Operations preserve the original and create separate temporary copies.")
            Text("Encrypted macOS conversion requires a matching V2 model. Only selected V2 models are used for this operation.")
        }
        .onAppear { artifacts.cleanup() }
    }

    private func perform(_ operation: UnfairPlayOperation, stripped: Bool = false) {
        session.start(operation, source: inputURL, package: package, stripAccountData: stripped)
    }
}

struct UnfairPlayReportView: View {
    let report: UnfairPlayReport
    let operation: UnfairPlayOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch operation {
            case .decrypt:
                Text("Decryption succeeded.")
                plaintextStatus
                if report.accountDataStripped == true {
                    Text("SC_Info licenses and supported account fields in iTunesMetadata.plist were removed.")
                }
            case .verify:
                Text("Verification completed without retaining a decrypted IPA.")
                plaintextStatus
            case .doctor:
                Text("Inspection completed.")
                if let ready = report.ready {
                    if ready { Text("A matching model is available.") }
                    else { Text("No matching model is available.") }
                }
            case .stripAccountData:
                Text("SC_Info licenses and supported account fields in iTunesMetadata.plist were removed.")
            case .convertIPAMacOS:
                Text("The new IPA is prepared for macOS. Its executables remain encrypted.")
            case .modelInspect:
                EmptyView()
            }
            if let count = report.encryptedImages, count >= 0 {
                LabeledContent("Encrypted images") { Text(count, format: .number) }
            }
            if let count = report.decryptedPages, count >= 0 {
                LabeledContent("Decrypted pages") { Text(count, format: .number) }
            }
            if let count = report.removedLicenseFiles, count >= 0 {
                LabeledContent("Removed license files") { Text(count, format: .number) }
            }
            if let count = report.removedMetadataFields, count >= 0 {
                LabeledContent("Removed account fields") { Text(count, format: .number) }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var plaintextStatus: some View {
        if report.plaintextVerified == true {
            Text("Plaintext hashes match for every decrypted image.")
        } else {
            Text("Plaintext hash coverage is unavailable for one or more images. Decryption success does not mean the plaintext was fully verified.")
        }
    }
}

extension UnfairPlayArtifact {
    var title: String {
        switch operation {
        case .decrypt:
            stripped ? String(localized: "Decrypted IPA (Account Data Stripped)") : String(localized: "Decrypted IPA")
        case .stripAccountData:
            String(localized: "IPA with Account Data Stripped")
        case .convertIPAMacOS:
            String(localized: "Encrypted IPA for macOS")
        default:
            String(localized: "Processed IPA")
        }
    }
}
