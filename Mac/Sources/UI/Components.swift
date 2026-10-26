import CoreImage.CIFilterBuiltins
import SpanscreenKit
import SwiftUI

enum Brand {
    static let accent = Color(red: 0.18, green: 0.42, blue: 1.0)
    static let usb = Color(red: 0.16, green: 0.72, blue: 0.47)
}

struct QRCodeView: View {
    let url: URL

    var body: some View {
        if let image = Self.render(url.absoluteString) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    private static func render(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct Pill: View {
    let text: LocalizedStringKey
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

struct SectionLabel: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

extension TextSize {
    var title: String {
        switch self {
        case .larger: return String(localized: "Larger")
        case .standard: return String(localized: "Default")
        case .moreSpace: return String(localized: "More Space")
        case .mostSpace: return String(localized: "Most Space")
        }
    }
}

extension StreamQuality {
    var title: String {
        switch self {
        case .efficient: return String(localized: "Efficient")
        case .balanced: return String(localized: "Balanced")
        case .best: return String(localized: "Best")
        }
    }
}

extension DisplayMode {
    var title: String { self == .extend ? String(localized: "Extend") : String(localized: "Mirror") }
}

func deviceSymbol(_ model: String) -> String {
    model.hasPrefix("iPad") ? "ipad.landscape" : "iphone.gen3"
}
