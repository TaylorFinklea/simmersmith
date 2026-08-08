import Foundation

struct OnboardingMintReceipt: Codable, Equatable {
    let version: Int
    let householdID: String
}

final class OnboardingMintReceiptStore: @unchecked Sendable {
    enum Error: Swift.Error, Equatable {
        case invalidHouseholdID
    }

    enum State: Equatable {
        case absent
        case valid(OnboardingMintReceipt)
        case malformed
    }

    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> State {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        do {
            let receipt = try JSONDecoder().decode(OnboardingMintReceipt.self, from: Data(contentsOf: fileURL))
            guard receipt.version == 1, !receipt.householdID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .malformed
            }
            return .valid(receipt)
        } catch {
            return .malformed
        }
    }

    func save(householdID: String) throws {
        guard !householdID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.invalidHouseholdID
        }
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableLifecycleFileSupport.write(
            try encoder.encode(OnboardingMintReceipt(version: 1, householdID: householdID)),
            to: fileURL
        )
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        try DurableLifecycleFileSupport.remove(fileURL)
    }
}
