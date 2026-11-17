import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct UnfairPlayModelsView: View {
    @State private var store = UnfairPlayModelStore.shared
    @State private var choosing = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Button("Import .bin Models") { choosing = true }
                    .disabled(store.importing || store.storageError != nil)
                if store.importing { ProgressView("Validating and saving models…") }
                LabeledContent("Selected model files") { Text(store.selectedCount, format: .number) }
                if let selectionError = store.selectionError { Text(selectionError).foregroundStyle(.red) }
                if let message = error ?? store.storageError {
                    Text(message).foregroundStyle(.red)
                }
                if store.storageError != nil {
                    Button("Retry Model Access") { store.reload() }
                }
            } footer: {
                Text("Models stay in this device’s private Keychain and are not synchronized. Import multi.bin or multiple supported model files.")
            }
            Section {
                if store.items.isEmpty { Text("No models imported.").foregroundStyle(.secondary) }
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Model File"); Text(index + 1, format: .number) }.font(.headline)
                        Button {
                            do {
                                try store.setSelected(!store.selectedIDs.contains(item.id), item: item)
                                error = nil
                            } catch { self.error = UnfairPlayError.modelStorage.localizedDescription }
                        } label: {
                            Label("Use this model", systemImage: store.selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.importing)
                        .accessibilityValue(store.selectedIDs.contains(item.id) ? String(localized: "Selected") : String(localized: "Not selected"))
                        LabeledContent("Contained models") { Text(item.modelCount, format: .number) }
                        Text(item.importedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        if !item.versions.isEmpty {
                            LabeledContent("Format versions", value: item.versions.map { String($0) }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Delete Model", role: .destructive) {
                            do { try store.remove(item); error = nil }
                            catch { self.error = UnfairPlayError.modelStorage.localizedDescription }
                        }
                        .disabled(store.importing)
                    }
                }
            } header: {
                Text("Saved Models")
            } footer: {
                Text("Import checks the model format. IPA operations authenticate the exact matching enrollment; other models are never tried as a fallback.")
                Text("Choose the models used by IPA operations. V2 and V3 models can be selected together. Select a V1 model alone for legacy IPAs. Encrypted macOS conversion uses only selected V2 models.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("FairPlay Models")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                Task {
                    do { error = nil; try await store.add(urls) }
                    catch { self.error = (error as? UnfairPlayError ?? .modelStorage).localizedDescription }
                }
            case .failure:
                error = UnfairPlayError.invalidModel.localizedDescription
            }
        }
    }
}
