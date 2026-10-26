import ApplicationServices
import CoreGraphics
import Foundation
import SpanscreenKit

final class InputInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var bounds = CGRect.zero
    private let source = CGEventSource(stateID: .hidSystemState)
    private var scrollRemainder = CGPoint.zero
    private var pressedButton: PointerButton?

    var targetBounds: CGRect {
        get { lock.withLock { bounds } }
        set { lock.withLock { bounds = newValue } }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func handle(_ event: InputEvent) {
        let rect = targetBounds
        guard rect.width > 0 else { return }
        switch event {
        case let .pointer(phase, button, x, y, clickCount):
            let point = CGPoint(x: rect.minX + CGFloat(min(max(x, 0), 0.9999)) * rect.width,
                                y: rect.minY + CGFloat(min(max(y, 0), 0.9999)) * rect.height)
            pointer(phase: phase, button: button, at: point, clickCount: clickCount)
        case let .relativeMove(dx, dy, dragging):
            let current = CGEvent(source: nil)?.location ?? CGPoint(x: rect.midX, y: rect.midY)
            let delta = CGPoint(x: CGFloat(dx) * rect.width, y: CGFloat(dy) * rect.height)
            let target = Self.clampToDisplays(CGPoint(x: current.x + delta.x, y: current.y + delta.y))
            let button = pressedButton ?? .left
            let type: CGEventType = dragging ? (button == .left ? .leftMouseDragged : .rightMouseDragged) : .mouseMoved
            if let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button == .left ? .left : .right) {
                e.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
                e.post(tap: .cghidEventTap)
            }
        case let .click(button, isDown, clickCount):
            let location = CGEvent(source: nil)?.location ?? CGPoint(x: rect.midX, y: rect.midY)
            pointer(phase: isDown ? .down : .up, button: button, at: location, clickCount: clickCount)
        case let .scroll(dx, dy, phase):
            scroll(dx: CGFloat(dx) * rect.width, dy: CGFloat(dy) * rect.height, phase: phase)
        case .magnify:
            break
        case let .keyboard(text):
            type(text)
        case let .key(code, modifiers, isDown):
            if let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) {
                e.flags = CGEventFlags(rawValue: UInt64(modifiers))
                e.post(tap: .cghidEventTap)
            }
        }
    }

    func releaseAll() {
        guard let button = pressedButton else { return }
        pressedButton = nil
        let location = CGEvent(source: nil)?.location ?? .zero
        let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button == .left ? .left : .right)?
            .post(tap: .cghidEventTap)
    }

    private func pointer(phase: PointerPhase, button: PointerButton, at point: CGPoint, clickCount: UInt8) {
        let type: CGEventType
        switch (phase, button) {
        case (.hover, _): type = .mouseMoved
        case (.down, .left): type = .leftMouseDown
        case (.down, .right): type = .rightMouseDown
        case (.drag, .left): type = .leftMouseDragged
        case (.drag, .right): type = .rightMouseDragged
        case (.up, .left): type = .leftMouseUp
        case (.up, .right): type = .rightMouseUp
        }
        if phase == .down { pressedButton = button }
        if phase == .up { pressedButton = nil }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button == .left ? .left : .right) else { return }
        if phase != .hover { e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount))) }
        e.post(tap: .cghidEventTap)
    }

    private func scroll(dx: CGFloat, dy: CGFloat, phase: ScrollPhase) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let x = scrollRemainder.x.rounded(.towardZero)
        let y = scrollRemainder.y.rounded(.towardZero)
        scrollRemainder.x -= x
        scrollRemainder.y -= y
        if phase == .ended || phase == .momentumEnded { scrollRemainder = .zero }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        switch phase {
        case .began: e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        case .changed: e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        case .ended: e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        case .momentumBegan: e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        case .momentum: e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        case .momentumEnded: e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3)
        }
        e.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) {
        for character in text {
            let units = Array(String(character).utf16)
            for isDown in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    private static func clampToDisplays(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let rects = ids.map(CGDisplayBounds)
        if rects.contains(where: { $0.contains(point) }) { return point }
        let nearest = rects.min { distance($0, point) < distance($1, point) } ?? .zero
        return CGPoint(x: min(max(point.x, nearest.minX), nearest.maxX - 1), y: min(max(point.y, nearest.minY), nearest.maxY - 1))
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
