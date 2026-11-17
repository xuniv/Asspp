import Foundation
import KeychainAccess
import Observation

/// Models and their catalog stay in a separate, nonsyncing device Keychain.
/// Original filenames and account/key selectors are never retained or shown.
@MainActor
@Observable
final class UnfairPlayModelStore {
    struct Item: Codable, Identifiable {
        let id: UUID
        let importedAt: Date
        let modelCount: Int
        let versions: [Int]
    }

    private struct Catalog: Codable {
        let version: Int
        let items: [Item]
        let selectedIDs: [UUID]?
    }

    static let shared = UnfairPlayModelStore()
    private let keychain = Keychain(service: "wiki.qaq.Asspp.UnfairPlay.Models")
        .synchronizable(false).accessibility(.whenUnlockedThisDeviceOnly)
    private(set) var items: [Item] = []
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var storageError: String?
    private(set) var importing = false

    private init() { reload() }

    func reload() {
        do {
            if let data = try keychain.getData("catalog") {
                guard data.count <= 256 * 1024 else { throw UnfairPlayError.modelStorage }
                let catalog = try JSONDecoder().decode(Catalog.self, from: data)
                guard catalog.version == 1, catalog.items.count <= 256,
                      Set(catalog.items.map(\.id)).count == catalog.items.count else { throw UnfairPlayError.modelStorage }
                for item in catalog.items {
                    guard let bytes = try keychain.getData(key(item.id)), [4176, 4184, 8708].contains(bytes.count) else {
                        throw UnfairPlayError.modelStorage
                    }
                }
                items = catalog.items
                let selected = Set(catalog.selectedIDs ?? catalog.items.filter { !$0.versions.contains(1) }.map(\.id))
                guard selected.isSubset(of: Set(items.map(\.id))) else { throw UnfairPlayError.modelStorage }
                selectedIDs = selected
            } else { items = []; selectedIDs = [] }
            storageError = nil
        } catch {
            storageError = UnfairPlayError.modelStorage.localizedDescription
        }
    }

    var selectedCount: Int { selectedIDs.count }
    var selectionError: String? {
        let selected = items.filter { selectedIDs.contains($0.id) }
        return selected.count > 1 && selected.contains(where: { $0.versions.contains(1) })
            ? UnfairPlayError.invalidSelection.localizedDescription : nil
    }

    func setSelected(_ selected: Bool, item: Item) throws {
        guard !importing, storageError == nil, items.contains(where: { $0.id == item.id }) else {
            throw UnfairPlayError.modelStorage
        }
        var updated = selectedIDs
        if selected { updated.insert(item.id) } else { updated.remove(item.id) }
        do {
            try saveCatalog(items, selected: updated)
            selectedIDs = updated
        } catch {
            try? saveCatalog(items, selected: selectedIDs)
            throw UnfairPlayError.modelStorage
        }
    }

    func modelData(for operation: UnfairPlayOperation) throws -> [Data] {
        if operation == .stripAccountData { return [] }
        var selected = items.filter { selectedIDs.contains($0.id) }
        if operation == .convertIPAMacOS {
            selected = selected.filter { $0.versions.contains(2) }
            guard !selected.isEmpty else { throw UnfairPlayError.requiresV2Model }
        } else if selectionError != nil { throw UnfairPlayError.invalidSelection }
        return try data(for: selected)
    }

    private func data(for entries: [Item]) throws -> [Data] {
        guard storageError == nil else { throw UnfairPlayError.modelStorage }
        return try entries.map {
            guard let data = try keychain.getData(key($0.id)), [4176, 4184, 8708].contains(data.count) else {
                throw UnfairPlayError.modelStorage
            }
            return data
        }
    }

    func add(_ sources: [URL]) async throws {
        guard !importing else { return }
        guard storageError == nil else { throw UnfairPlayError.modelStorage }
        guard !sources.isEmpty, sources.count <= 256 - items.count else { throw UnfairPlayError.modelLimit }
        importing = true
        defer { importing = false }
        let oldItems = items
        let oldSelected = selectedIDs
        let saved = try data(for: items)
        var incoming: [Data] = []
        for source in sources {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let data = try await Task.detached(priority: .userInitiated) {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, [4176, 4184, 8708].contains(size) else { throw UnfairPlayError.invalidModel }
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                guard let bytes = try handle.read(upToCount: 8709), bytes.count == size else { throw UnfairPlayError.invalidModel }
                return bytes
            }.value
            if !saved.contains(data), !incoming.contains(data) { incoming.append(data) }
        }
        guard !incoming.isEmpty else { throw UnfairPlayError.duplicateModel }
        // Envelope validation only. Exact enrollment matching remains the
        // native engine's authenticated per-IPA selection, with no fallback.
        _ = try await UnfairPlayRuntime.shared.run(.modelInspect, models: saved + incoming)
        var additions: [Item] = []
        for data in incoming {
            let report = try await UnfairPlayRuntime.shared.run(.modelInspect, models: [data])
            guard let count = report.modelCount, (1 ... 256).contains(count) else { throw UnfairPlayError.invalidModel }
            additions.append(Item(id: UUID(), importedAt: Date(), modelCount: count, versions: report.modelVersions ?? []))
        }
        do {
            for (item, data) in zip(additions, incoming) {
                try keychain.set(data, key: key(item.id))
                guard try keychain.getData(key(item.id)) == data else { throw UnfairPlayError.modelStorage }
            }
            // Legacy V1 models require explicit single-model selection. Modern
            // models may be selected together, without changing a chosen V1.
            let selectedV1 = oldItems.contains { oldSelected.contains($0.id) && $0.versions.contains(1) }
            let modern = selectedV1 ? [] : additions.filter { !$0.versions.contains(1) }.map(\.id)
            let updated = oldSelected.union(modern)
            try saveCatalog(oldItems + additions, selected: updated)
            items = oldItems + additions
            selectedIDs = updated
        } catch {
            for item in additions { try? keychain.remove(key(item.id)) }
            try? saveCatalog(oldItems, selected: oldSelected)
            throw UnfairPlayError.modelStorage
        }
    }

    func remove(_ item: Item) throws {
        guard !importing, let data = try keychain.getData(key(item.id)) else { throw UnfairPlayError.modelStorage }
        let previous = items
        let previousSelection = selectedIDs
        do {
            try keychain.remove(key(item.id))
            let remaining = items.filter { $0.id != item.id }
            let selected = selectedIDs.subtracting([item.id])
            try saveCatalog(remaining, selected: selected)
            items = remaining
            selectedIDs = selected
        } catch {
            try? keychain.set(data, key: key(item.id))
            try? saveCatalog(previous, selected: previousSelection)
            throw UnfairPlayError.modelStorage
        }
    }

    private func key(_ id: UUID) -> String { "model." + id.uuidString }
    private func saveCatalog(_ values: [Item], selected: Set<UUID>) throws {
        let data = try JSONEncoder().encode(Catalog(version: 1, items: values, selectedIDs: selected.sorted { $0.uuidString < $1.uuidString }))
        try keychain.set(data, key: "catalog")
        guard try keychain.getData("catalog") == data else { throw UnfairPlayError.modelStorage }
    }
}
