import Foundation

public enum PointerButton: UInt8, Codable, Sendable {
    case left = 0
    case right = 1
}

public enum PointerPhase: UInt8, Codable, Sendable {
    case down = 0
    case drag = 1
    case up = 2
    case hover = 3
}

public enum ScrollPhase: UInt8, Codable, Sendable {
    case began = 0
    case changed = 1
    case ended = 2
    case momentumBegan = 3
    case momentum = 4
    case momentumEnded = 5
}

public enum InputEvent: Equatable, Sendable {
    case pointer(phase: PointerPhase, button: PointerButton, x: Float, y: Float, clickCount: UInt8)
    case relativeMove(dx: Float, dy: Float, dragging: Bool)
    case click(button: PointerButton, isDown: Bool, clickCount: UInt8)
    case scroll(dx: Float, dy: Float, phase: ScrollPhase)
    case magnify(amount: Float, phase: ScrollPhase)
    case keyboard(text: String)
    case key(code: UInt16, modifiers: UInt32, isDown: Bool)
}

extension InputEvent {
    private enum Tag: UInt8 {
        case pointer = 1, relativeMove, click, scroll, magnify, keyboard, key
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case let .pointer(phase, button, x, y, clickCount):
            w.u8(Tag.pointer.rawValue); w.u8(phase.rawValue); w.u8(button.rawValue); w.f32(x); w.f32(y); w.u8(clickCount)
        case let .relativeMove(dx, dy, dragging):
            w.u8(Tag.relativeMove.rawValue); w.f32(dx); w.f32(dy); w.u8(dragging ? 1 : 0)
        case let .click(button, isDown, clickCount):
            w.u8(Tag.click.rawValue); w.u8(button.rawValue); w.u8(isDown ? 1 : 0); w.u8(clickCount)
        case let .scroll(dx, dy, phase):
            w.u8(Tag.scroll.rawValue); w.f32(dx); w.f32(dy); w.u8(phase.rawValue)
        case let .magnify(amount, phase):
            w.u8(Tag.magnify.rawValue); w.f32(amount); w.u8(phase.rawValue)
        case let .keyboard(text):
            w.u8(Tag.keyboard.rawValue); w.bytes(Data(text.utf8))
        case let .key(code, modifiers, isDown):
            w.u8(Tag.key.rawValue); w.u16(code); w.u32(modifiers); w.u8(isDown ? 1 : 0)
        }
        return w.data
    }

    public init?(_ data: Data) {
        var r = ByteReader(data)
        guard let raw = r.u8(), let tag = Tag(rawValue: raw) else { return nil }
        switch tag {
        case .pointer:
            guard let p = r.u8().flatMap(PointerPhase.init), let b = r.u8().flatMap(PointerButton.init),
                  let x = r.f32(), let y = r.f32(), let c = r.u8() else { return nil }
            self = .pointer(phase: p, button: b, x: x, y: y, clickCount: c)
        case .relativeMove:
            guard let dx = r.f32(), let dy = r.f32(), let d = r.u8() else { return nil }
            self = .relativeMove(dx: dx, dy: dy, dragging: d == 1)
        case .click:
            guard let b = r.u8().flatMap(PointerButton.init), let d = r.u8(), let c = r.u8() else { return nil }
            self = .click(button: b, isDown: d == 1, clickCount: c)
        case .scroll:
            guard let dx = r.f32(), let dy = r.f32(), let p = r.u8().flatMap(ScrollPhase.init) else { return nil }
            self = .scroll(dx: dx, dy: dy, phase: p)
        case .magnify:
            guard let a = r.f32(), let p = r.u8().flatMap(ScrollPhase.init) else { return nil }
            self = .magnify(amount: a, phase: p)
        case .keyboard:
            guard let text = String(data: r.rest(), encoding: .utf8) else { return nil }
            self = .keyboard(text: text)
        case .key:
            guard let code = r.u16(), let mods = r.u32(), let d = r.u8() else { return nil }
            self = .key(code: code, modifiers: mods, isDown: d == 1)
        }
    }
}
