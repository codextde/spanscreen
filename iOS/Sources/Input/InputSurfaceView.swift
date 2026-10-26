import SpanscreenKit
import UIKit

final class InputSurfaceView: UIView, UIKeyInput {
    var send: ((InputEvent) -> Void)?
    var onThreeFingerTap: (() -> Void)?
    var mode: TouchMode = .touch
    var trackpadSpeed: CGFloat = 1
    var videoSize: CGSize = .zero
    var onGeometry: ((CGRect, UIEdgeInsets, CGFloat, Int) -> Void)?
    var contentRect: CGRect = .zero {
        didSet { setNeedsLayout() }
    }

    let videoLayer: CALayer
    var demoLayer: CALayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let demoLayer { layer.addSublayer(demoLayer) }
            setNeedsLayout()
        }
    }

    private enum Gesture {
        case idle
        case pending(start: CGPoint, time: TimeInterval)
        case dragging(last: CGPoint)
        case moving(last: CGPoint, dragging: Bool)
        case twoFinger(start: CGPoint, last: CGPoint, time: TimeInterval, scrolling: Bool)
        case threeFinger(time: TimeInterval)
        case finishing
    }

    private var gesture = Gesture.idle
    private var touches = Set<UITouch>()
    private var primary: UITouch?
    private var holdTimer: Timer?
    private var lastTap: (time: TimeInterval, point: CGPoint, count: UInt8)?
    private var scrollVelocity = CGPoint.zero
    private var lastScrollTime: TimeInterval = 0
    private var lastMoveTime: TimeInterval = 0
    private var momentumLink: CADisplayLink?
    private let haptics = UIImpactFeedbackGenerator(style: .medium)

    init(videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        layer.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = contentRect == .zero ? bounds : contentRect
        demoLayer?.frame = videoLayer.frame
        CATransaction.commit()
        let screen = window?.windowScene?.screen
        onGeometry?(bounds, safeAreaInsets, screen?.nativeScale ?? traitCollection.displayScale, screen?.maximumFramesPerSecond ?? 60)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    private var videoRect: CGRect {
        let box = contentRect == .zero ? bounds : contentRect
        guard videoSize.width > 0, videoSize.height > 0 else { return box }
        let scale = min(box.width / videoSize.width, box.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func normalized(_ point: CGPoint) -> (Float, Float) {
        let rect = videoRect
        return (Float((point.x - rect.minX) / rect.width), Float((point.y - rect.minY) / rect.height))
    }

    private func normalizedDelta(_ delta: CGPoint) -> CGPoint {
        let rect = videoRect
        return CGPoint(x: delta.x / rect.width, y: delta.y / rect.height)
    }

    private var centroid: CGPoint {
        let points = touches.map { $0.location(in: self) }
        guard !points.isEmpty else { return .zero }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    override func touchesBegan(_ newTouches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum()
        touches.formUnion(newTouches)
        let now = CACurrentMediaTime()
        switch (touches.count, gesture) {
        case (1, .idle):
            primary = newTouches.first
            let point = newTouches.first!.location(in: self)
            gesture = .pending(start: point, time: now)
            haptics.prepare()
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: mode == .touch ? 0.45 : 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdFired() }
            }
        case (2, .pending), (2, .idle):
            holdTimer?.invalidate()
            let c = centroid
            gesture = .twoFinger(start: c, last: c, time: now, scrolling: false)
        case (3, .twoFinger), (3, .pending), (3, .idle):
            holdTimer?.invalidate()
            if case .twoFinger(_, _, _, true) = gesture { emitScroll(.zero, phase: .ended) }
            gesture = .threeFinger(time: now)
        default:
            break
        }
    }

    private func holdFired() {
        guard case let .pending(start, _) = gesture else { return }
        haptics.impactOccurred()
        switch mode {
        case .touch:
            let (x, y) = normalized(start)
            send?(.pointer(phase: .down, button: .right, x: x, y: y, clickCount: 1))
            send?(.pointer(phase: .up, button: .right, x: x, y: y, clickCount: 1))
            gesture = .finishing
        case .trackpad:
            send?(.click(button: .left, isDown: true, clickCount: 1))
            gesture = .moving(last: start, dragging: true)
        }
    }

    override func touchesMoved(_ moved: Set<UITouch>, with event: UIEvent?) {
        let now = CACurrentMediaTime()
        switch gesture {
        case let .pending(start, _):
            guard let touch = primary, moved.contains(touch) else { return }
            let point = touch.location(in: self)
            guard hypot(point.x - start.x, point.y - start.y) > (mode == .touch ? 8 : 3) else { return }
            holdTimer?.invalidate()
            if mode == .touch {
                let (sx, sy) = normalized(start)
                let (x, y) = normalized(point)
                send?(.pointer(phase: .down, button: .left, x: sx, y: sy, clickCount: 1))
                send?(.pointer(phase: .drag, button: .left, x: x, y: y, clickCount: 1))
                gesture = .dragging(last: point)
            } else {
                relativeMove(from: start, to: point, dragging: false, touch: touch)
                gesture = .moving(last: point, dragging: false)
            }
        case .dragging:
            guard let touch = primary, moved.contains(touch) else { return }
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                let (x, y) = normalized(sample.location(in: self))
                send?(.pointer(phase: .drag, button: .left, x: x, y: y, clickCount: 1))
            }
            gesture = .dragging(last: touch.location(in: self))
        case let .moving(last, dragging):
            guard let touch = primary, moved.contains(touch) else { return }
            let point = touch.location(in: self)
            relativeMove(from: last, to: point, dragging: dragging, touch: touch)
            gesture = .moving(last: point, dragging: dragging)
        case let .twoFinger(start, last, time, scrolling):
            let c = centroid
            if !scrolling {
                guard hypot(c.x - start.x, c.y - start.y) > 6 else { return }
                if mode == .touch {
                    let (x, y) = normalized(start)
                    send?(.pointer(phase: .hover, button: .left, x: x, y: y, clickCount: 0))
                }
                scrollVelocity = .zero
                lastScrollTime = now
                emitScroll(CGPoint(x: c.x - start.x, y: c.y - start.y), phase: .began)
                gesture = .twoFinger(start: start, last: c, time: time, scrolling: true)
                return
            }
            let delta = CGPoint(x: c.x - last.x, y: c.y - last.y)
            let dt = max(now - lastScrollTime, 1.0 / 240)
            lastScrollTime = now
            scrollVelocity = CGPoint(x: scrollVelocity.x * 0.4 + delta.x / dt * 0.6, y: scrollVelocity.y * 0.4 + delta.y / dt * 0.6)
            emitScroll(delta, phase: .changed)
            gesture = .twoFinger(start: start, last: c, time: time, scrolling: true)
        default:
            break
        }
    }

    override func touchesEnded(_ ended: Set<UITouch>, with event: UIEvent?) {
        finish(ended, cancelled: false)
    }

    override func touchesCancelled(_ cancelled: Set<UITouch>, with event: UIEvent?) {
        finish(cancelled, cancelled: true)
    }

    private func finish(_ lifted: Set<UITouch>, cancelled: Bool) {
        let now = CACurrentMediaTime()
        let primaryLifted = primary.map(lifted.contains) ?? false
        switch gesture {
        case let .pending(start, time) where primaryLifted:
            holdTimer?.invalidate()
            if !cancelled, now - time < 0.45 { tap(at: start, now: now) }
            gesture = .finishing
        case let .dragging(last) where primaryLifted:
            let (x, y) = normalized(primary?.location(in: self) ?? last)
            send?(.pointer(phase: .up, button: .left, x: x, y: y, clickCount: 1))
            gesture = .finishing
        case let .moving(_, dragging) where primaryLifted:
            if dragging { send?(.click(button: .left, isDown: false, clickCount: 1)) }
            gesture = .finishing
        case let .twoFinger(start, _, time, scrolling):
            if scrolling {
                emitScroll(.zero, phase: .ended)
                if now - lastScrollTime < 0.08, hypot(scrollVelocity.x, scrollVelocity.y) > 120 { startMomentum() }
            } else if !cancelled, now - time < 0.35 {
                rightClick(at: start)
            }
            gesture = .finishing
        case let .threeFinger(time):
            if !cancelled, now - time < 0.4 { onThreeFingerTap?() }
            gesture = .finishing
        default:
            break
        }
        touches.subtract(lifted)
        touches = touches.filter { $0.phase != .ended && $0.phase != .cancelled }
        if touches.isEmpty {
            gesture = .idle
            primary = nil
            holdTimer?.invalidate()
        }
    }

    private func tap(at point: CGPoint, now: TimeInterval) {
        var count: UInt8 = 1
        if let lastTap, now - lastTap.time < 0.35, hypot(point.x - lastTap.point.x, point.y - lastTap.point.y) < 32 {
            count = min(lastTap.count + 1, 3)
        }
        lastTap = (now, point, count)
        switch mode {
        case .touch:
            let (x, y) = normalized(point)
            send?(.pointer(phase: .down, button: .left, x: x, y: y, clickCount: count))
            send?(.pointer(phase: .up, button: .left, x: x, y: y, clickCount: count))
        case .trackpad:
            send?(.click(button: .left, isDown: true, clickCount: count))
            send?(.click(button: .left, isDown: false, clickCount: count))
        }
    }

    private func rightClick(at point: CGPoint) {
        haptics.impactOccurred(intensity: 0.6)
        switch mode {
        case .touch:
            let (x, y) = normalized(point)
            send?(.pointer(phase: .down, button: .right, x: x, y: y, clickCount: 1))
            send?(.pointer(phase: .up, button: .right, x: x, y: y, clickCount: 1))
        case .trackpad:
            send?(.click(button: .right, isDown: true, clickCount: 1))
            send?(.click(button: .right, isDown: false, clickCount: 1))
        }
    }

    private func relativeMove(from: CGPoint, to: CGPoint, dragging: Bool, touch: UITouch) {
        let delta = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let dt = min(max(touch.timestamp - lastMoveTime, 1.0 / 240), 0.1)
        lastMoveTime = touch.timestamp
        let speed = hypot(delta.x, delta.y) / dt
        let gain = trackpadSpeed * (1.1 + min(speed / 900, 2.2))
        let n = normalizedDelta(CGPoint(x: delta.x * gain, y: delta.y * gain))
        send?(.relativeMove(dx: Float(n.x), dy: Float(n.y), dragging: dragging))
    }

    private func emitScroll(_ delta: CGPoint, phase: ScrollPhase) {
        let n = normalizedDelta(delta)
        send?(.scroll(dx: Float(n.x), dy: Float(n.y), phase: phase))
    }

    private func startMomentum() {
        stopMomentum()
        emitScroll(.zero, phase: .momentumBegan)
        let link = CADisplayLink(target: self, selector: #selector(momentumStep(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func momentumStep(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        let decay = pow(0.0025, dt)
        scrollVelocity = CGPoint(x: scrollVelocity.x * decay, y: scrollVelocity.y * decay)
        if hypot(scrollVelocity.x, scrollVelocity.y) < 20 {
            stopMomentum()
            return
        }
        emitScroll(CGPoint(x: scrollVelocity.x * dt, y: scrollVelocity.y * dt), phase: .momentum)
    }

    private func stopMomentum() {
        guard let momentumLink else { return }
        momentumLink.invalidate()
        self.momentumLink = nil
        emitScroll(.zero, phase: .momentumEnded)
    }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var keyboardType: UIKeyboardType = .default
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var spellCheckingType: UITextSpellCheckingType = .no

    func insertText(_ text: String) {
        if text == "\n" {
            key(36)
        } else if text == "\t" {
            key(48)
        } else {
            send?(.keyboard(text: text))
        }
    }

    func deleteBackward() { key(51) }

    private func key(_ code: UInt16) {
        send?(.key(code: code, modifiers: 0, isDown: true))
        send?(.key(code: code, modifiers: 0, isDown: false))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let code = Self.macKeyCode(key.keyCode) else { continue }
            send?(.key(code: code, modifiers: Self.macModifiers(key.modifierFlags), isDown: true))
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let code = Self.macKeyCode(key.keyCode) else { continue }
            send?(.key(code: code, modifiers: Self.macModifiers(key.modifierFlags), isDown: false))
            handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key, let code = Self.macKeyCode(key.keyCode) else { continue }
            send?(.key(code: code, modifiers: 0, isDown: false))
        }
        super.pressesCancelled(presses, with: event)
    }

    private static func macModifiers(_ flags: UIKeyModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.shift) { value |= 1 << 17 }
        if flags.contains(.control) { value |= 1 << 18 }
        if flags.contains(.alternate) { value |= 1 << 19 }
        if flags.contains(.command) { value |= 1 << 20 }
        return value
    }

    private static func macKeyCode(_ code: UIKeyboardHIDUsage) -> UInt16? {
        let map: [UIKeyboardHIDUsage: UInt16] = [
            .keyboardA: 0, .keyboardS: 1, .keyboardD: 2, .keyboardF: 3, .keyboardH: 4, .keyboardG: 5, .keyboardZ: 6, .keyboardX: 7,
            .keyboardC: 8, .keyboardV: 9, .keyboardB: 11, .keyboardQ: 12, .keyboardW: 13, .keyboardE: 14, .keyboardR: 15, .keyboardY: 16,
            .keyboardT: 17, .keyboard1: 18, .keyboard2: 19, .keyboard3: 20, .keyboard4: 21, .keyboard6: 22, .keyboard5: 23, .keyboardEqualSign: 24,
            .keyboard9: 25, .keyboard7: 26, .keyboardHyphen: 27, .keyboard8: 28, .keyboard0: 29, .keyboardCloseBracket: 30, .keyboardO: 31,
            .keyboardU: 32, .keyboardOpenBracket: 33, .keyboardI: 34, .keyboardP: 35, .keyboardReturnOrEnter: 36, .keyboardL: 37, .keyboardJ: 38,
            .keyboardQuote: 39, .keyboardK: 40, .keyboardSemicolon: 41, .keyboardBackslash: 42, .keyboardComma: 43, .keyboardSlash: 44,
            .keyboardN: 45, .keyboardM: 46, .keyboardPeriod: 47, .keyboardTab: 48, .keyboardSpacebar: 49, .keyboardGraveAccentAndTilde: 50,
            .keyboardDeleteOrBackspace: 51, .keyboardEscape: 53, .keyboardDeleteForward: 117, .keyboardHome: 115, .keyboardEnd: 119,
            .keyboardPageUp: 116, .keyboardPageDown: 121, .keyboardLeftArrow: 123, .keyboardRightArrow: 124, .keyboardDownArrow: 125, .keyboardUpArrow: 126
        ]
        return map[code]
    }
}
