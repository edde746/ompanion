import Flutter
import UIKit
import UniformTypeIdentifiers

/// The system's Paste of a copied image, over the `ompanion/clipboard` channel. Flutter's text field offers Paste for
/// text only, and iOS lets the app read another app's copy only through the item providers a paste the user started
/// from the system's own menu hands over: read from UIPasteboard instead it asks first, and once the copy is a little
/// old it refuses without asking. So the app delegate, the last responder, accepts images (its pasteConfiguration),
/// which puts the system's Paste in the menu while the field declines it, and hands what it pastes to Dart.
final class ImagePaste {
  static let configuration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])

  /// The types omp takes as image content, sent as copied; anything else is sent as PNG.
  private static let imageTypes: Set<String> = [
    UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier,
  ]

  private var channel: FlutterMethodChannel?

  func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ompanion/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      // The types on the pasteboard, not its content, so asking never prompts.
      case "hasImage":
        result(UIPasteboard.general.itemProviders.contains { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
      default: result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// Sends each copied image in order; null for one that could not be read.
  func paste(_ itemProviders: [NSItemProvider]) {
    let providers = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    var images = [Data?](repeating: nil, count: providers.count)
    let loads = DispatchGroup()
    for (index, provider) in providers.enumerated() {
      loads.enter()
      if let type = provider.registeredTypeIdentifiers.first(where: Self.imageTypes.contains) {
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
          DispatchQueue.main.async {
            images[index] = data
            loads.leave()
          }
        }
      } else {
        provider.loadObject(ofClass: UIImage.self) { image, _ in
          let png = (image as? UIImage)?.pngData()
          DispatchQueue.main.async {
            images[index] = png
            loads.leave()
          }
        }
      }
    }
    loads.notify(queue: .main) { [weak self] in
      for image in images {
        self?.channel?.invokeMethod("paste", arguments: image.map { FlutterStandardTypedData(bytes: $0) })
      }
    }
  }
}
