import CoreGraphics
import Foundation

enum DisplayPosition: String, CaseIterable, Codable, Identifiable {
    case left, right, above, below
    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        case .above: return String(localized: "Above")
        case .below: return String(localized: "Below")
        }
    }
}

@MainActor
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    let maxPixels: Int
    private(set) var points = CGSize.zero
    private(set) var refreshRate: Double = 60

    init?(name: String, serial: UInt32, sizeInMillimeters: CGSize, maxPixels: Int) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(maxPixels)
        descriptor.maxPixelsHigh = UInt32(maxPixels)
        descriptor.sizeInMillimeters = sizeInMillimeters
        descriptor.vendorID = 0x5353
        descriptor.productID = 0x0001
        descriptor.serialNum = serial
        descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.terminationHandler = { _, _ in }
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        self.display = display
        self.displayID = display.displayID
        self.maxPixels = maxPixels
    }

    func fits(points size: CGSize) -> Bool {
        Int(size.width * 2) <= maxPixels && Int(size.height * 2) <= maxPixels
    }

    func configure(points size: CGSize, refreshRate: Double) async -> Bool {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        let rates = refreshRate > 60 ? [refreshRate, 60] : [60]
        settings.modes = rates.map {
            CGVirtualDisplayMode(width: UInt(size.width), height: UInt(size.height), refreshRate: $0)
        }
        guard display.apply(settings) else { return false }
        points = size
        self.refreshRate = refreshRate
        for _ in 0..<40 {
            if selectRetinaMode() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    var bounds: CGRect { CGDisplayBounds(displayID) }

    private func selectRetinaMode() -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return false }
        let width = Int(points.width), height = Int(points.height)
        let candidates = modes.filter { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }
        guard let mode = candidates.min(by: { abs($0.refreshRate - refreshRate) < abs($1.refreshRate - refreshRate) }) else {
            return false
        }
        if let current = CGDisplayCopyDisplayMode(displayID), current.ioDisplayModeID == mode.ioDisplayModeID {
            return true
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    func place(_ position: DisplayPosition) {
        let main = CGDisplayBounds(CGMainDisplayID())
        let size = bounds.size
        let origin: CGPoint
        switch position {
        case .right: origin = CGPoint(x: main.maxX, y: main.midY - size.height / 2)
        case .left: origin = CGPoint(x: main.minX - size.width, y: main.midY - size.height / 2)
        case .above: origin = CGPoint(x: main.midX - size.width / 2, y: main.minY - size.height)
        case .below: origin = CGPoint(x: main.midX - size.width / 2, y: main.maxY)
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    var currentPosition: DisplayPosition? {
        let main = CGDisplayBounds(CGMainDisplayID())
        let rect = bounds
        if rect.minX >= main.maxX - 1 { return .right }
        if rect.maxX <= main.minX + 1 { return .left }
        if rect.maxY <= main.minY + 1 { return .above }
        if rect.minY >= main.maxY - 1 { return .below }
        return nil
    }

    static func serial(for deviceID: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in deviceID.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }
}
