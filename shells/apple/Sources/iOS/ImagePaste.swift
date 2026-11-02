import UIKit
import UniformTypeIdentifiers

/// The system's Paste of copied images, sent to the page as `shell.pasteFiles` (docs/contracts/bridge.md). The page's
/// text fields offer Paste for text only, and iOS lets the app read another app's copy only through the item providers
/// a paste the user started from the system's own menu hands over: read from UIPasteboard instead it asks first, and
/// once the copy is a little old it refuses without asking. So the app delegate, the last responder, accepts images
/// (its pasteConfiguration), which puts the system's Paste in the menu while the web view declines it, and hands what
/// it pastes to the page as files in the cache folder, which the page loads from `cache/<name>`.
@MainActor
enum ImagePaste {
    static let configuration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])

    /// The types omp takes as image content, written as copied; anything else is written as PNG.
    private static let imageTypes: Set<String> = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier,
    ]

    /// Writes each copied image to `cache` and returns them in order, as `{url, name, mimeType}`; one that could not be
    /// read is logged and left out.
    static func files(_ providers: [NSItemProvider], cache: URL) async -> [[String: String]] {
        var files: [[String: String]] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            do {
                let (data, type) = try await image(provider)
                let fileExtension = type.preferredFilenameExtension ?? "png"
                let name = "paste-\(UUID().uuidString).\(fileExtension)"
                try data.write(to: cache.appendingPathComponent(name))
                files.append([
                    "url": "cache/\(name)", "name": "image.\(fileExtension)",
                    "mimeType": type.preferredMIMEType ?? "image/png",
                ])
            } catch {
                NSLog("shell: a pasted image could not be read: %@", error.localizedDescription)
            }
        }
        return files
    }

    private static func image(_ provider: NSItemProvider) async throws -> (Data, UTType) {
        // The first of the copy's own types, in the order it lists them, that omp takes.
        if let identifier = provider.registeredTypeIdentifiers.first(where: imageTypes.contains),
           let type = UTType(identifier) {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                    if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: error ?? ShellError("no \(identifier) data"))
                    }
                }
            }
            return (data, type)
        }
        let png: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { image, error in
                if let png = (image as? UIImage)?.pngData() {
                    continuation.resume(returning: png)
                } else {
                    continuation.resume(throwing: error ?? ShellError("the image has no PNG form"))
                }
            }
        }
        return (png, .png)
    }
}
