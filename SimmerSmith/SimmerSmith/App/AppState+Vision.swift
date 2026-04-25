import Foundation
import SimmerSmithKit

extension AppState {
    /// Send an image to the backend's vision-AI route and decode an
    /// `IngredientIdentification` response. The caller (typically
    /// `IngredientScannerView`) is responsible for converting the source
    /// (camera capture or PhotosPicker) to JPEG `Data` before calling.
    func identifyIngredient(imageData: Data) async throws -> IngredientIdentification {
        try await apiClient.identifyIngredient(imageData: imageData, mimeType: "image/jpeg")
    }

    /// Reverse-lookup a Kroger product by UPC at the user's currently
    /// selected store. The caller is responsible for surfacing the
    /// "no store selected" state — the route 503s without a configured
    /// location, but we want a friendlier error before the request leaves
    /// the device.
    func lookupProductByUPC(_ upc: String) async throws -> ProductLookup {
        let locationID = profile?.settings["kroger_location_id"] ?? ""
        guard !locationID.isEmpty else {
            throw VisionError.noStoreSelected
        }
        return try await apiClient.lookupProductByUPC(upc: upc, locationID: locationID)
    }
}

enum VisionError: LocalizedError {
    case noStoreSelected

    var errorDescription: String? {
        switch self {
        case .noStoreSelected:
            return "Pick a Kroger store in Settings before scanning."
        }
    }
}
