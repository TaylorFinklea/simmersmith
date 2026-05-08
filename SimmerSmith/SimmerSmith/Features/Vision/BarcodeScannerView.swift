import SimmerSmithKit
import SwiftUI
import VisionKit

/// Live barcode scanner backed by `DataScannerViewController`. Calls
/// `onScan` once with the first recognized barcode payload, then it's the
/// host view's responsibility to dismiss this scanner and present the
/// product lookup result.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        guard !context.coordinator.didFire else { return }
        do {
            try uiViewController.startScanning()
        } catch {
            onError(error.localizedDescription)
        }
    }

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        var didFire = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(items: addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            handle(items: [item])
        }

        private func handle(items: [RecognizedItem]) {
            guard !didFire else { return }
            for item in items {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue,
                   !payload.isEmpty {
                    didFire = true
                    onScan(payload)
                    return
                }
            }
        }
    }
}

/// Sheet that presents the live scanner, shows a result card on a hit,
/// and surfaces an error or fallback when the lookup fails.
struct BarcodeLookupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var scannedUPC: String?
    @State private var lookupResult: ProductLookup?
    @State private var isLookingUp = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if let result = lookupResult {
                    resultView(result)
                } else if let scannedUPC, isLookingUp {
                    progressView(for: scannedUPC)
                } else if let errorMessage {
                    errorView(errorMessage)
                } else {
                    BarcodeScannerView(
                        onScan: { upc in
                            scannedUPC = upc
                            Task { await lookup(upc: upc) }
                        },
                        onCancel: { dismiss() },
                        onError: { msg in errorMessage = msg }
                    )
                    .ignoresSafeArea()
                }
            }
            .navigationTitle(scannedUPC == nil ? "Scan barcode" : "Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                if lookupResult != nil || errorMessage != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Scan again") { reset() }
                            .foregroundStyle(SMColor.ember)
                    }
                }
            }
            .smithToolbar()
        }
    }

    @ViewBuilder
    private func progressView(for upc: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking up UPC \(upc)…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private func resultView(_ result: ProductLookup) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if !result.brand.isEmpty {
                        Text(result.brand).font(.title3.bold())
                    }
                    Text(result.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    if !result.packageSize.isEmpty {
                        Text(result.packageSize)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Section("Pricing") {
                if let regular = result.regularPrice {
                    HStack {
                        Text("Regular")
                        Spacer()
                        Text(String(format: "$%.2f", regular))
                            .monospacedDigit()
                    }
                }
                if let promo = result.promoPrice {
                    HStack {
                        Text("Promo")
                        Spacer()
                        Text(String(format: "$%.2f", promo))
                            .monospacedDigit()
                            .foregroundStyle(.green)
                    }
                }
                HStack {
                    Text("In stock")
                    Spacer()
                    Text(result.inStock ? "Yes" : "No")
                        .foregroundStyle(result.inStock ? .green : .secondary)
                }
            }
            Section {
                Text("UPC \(result.upc)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func reset() {
        scannedUPC = nil
        lookupResult = nil
        errorMessage = nil
        isLookingUp = false
    }

    private func lookup(upc: String) async {
        isLookingUp = true
        errorMessage = nil
        defer { isLookingUp = false }
        do {
            let result = try await appState.lookupProductByUPC(upc)
            self.lookupResult = result
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
