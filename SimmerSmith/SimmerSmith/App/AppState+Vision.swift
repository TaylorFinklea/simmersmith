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
}
