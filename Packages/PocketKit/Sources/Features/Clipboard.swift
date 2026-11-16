#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// The clipboard holds an image (checked without reading it, so no paste prompt appears).
    static var hasImage: Bool {
        #if canImport(UIKit)
        UIPasteboard.general.hasImages
        #elseif canImport(AppKit)
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        #endif
    }

    /// The clipboard's image as PNG or JPEG data. Reading it may show the system paste prompt.
    static func imageData() -> Data? {
        #if canImport(UIKit)
        let board = UIPasteboard.general
        if let data = board.data(forPasteboardType: "public.png") ?? board.data(forPasteboardType: "public.jpeg") {
            return data
        }
        return board.image?.pngData()
        #elseif canImport(AppKit)
        let board = NSPasteboard.general
        if let data = board.data(forType: .png) { return data }
        if let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
        #endif
    }
}
