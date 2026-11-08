import Darwin
import Foundation
import GameController
import UIKit

enum ManicSkinInputMapper {
    static let menuInput = "menu"
    static let toggleAnalogInput = "toggleAnalog"
    static let xboxLeftThumbstick = "xboxLeftThumbstick"
    static let xboxRightThumbstick = "xboxRightThumbstick"

    enum TriggerAxis {
        case left
        case right
    }

    enum CoreButton {
        static let a: UInt32 = 1 << 0
        static let b: UInt32 = 1 << 1
        static let x: UInt32 = 1 << 2
        static let y: UInt32 = 1 << 3
        static let dpadLeft: UInt32 = 1 << 4
        static let dpadUp: UInt32 = 1 << 5
        static let dpadRight: UInt32 = 1 << 6
        static let dpadDown: UInt32 = 1 << 7
        static let back: UInt32 = 1 << 8
        static let start: UInt32 = 1 << 9
        static let white: UInt32 = 1 << 10
        static let black: UInt32 = 1 << 11
        static let leftThumb: UInt32 = 1 << 12
        static let rightThumb: UInt32 = 1 << 13
    }

    private static let buttonMasks: [String: UInt32] = [
        "a": CoreButton.a,
        "b": CoreButton.b,
        "x": CoreButton.x,
        "y": CoreButton.y,
        "l1": CoreButton.white,
        "r1": CoreButton.black,
        "l3": CoreButton.leftThumb,
        "r3": CoreButton.rightThumb,
        "start": CoreButton.start,
        "select": CoreButton.back
    ]

    private static let triggerAxes: [String: TriggerAxis] = [
        "l2": .left,
        "r2": .right
    ]

    private static let digitalDirections: Set<String> = ["up", "down", "left", "right"]

    static func buttonMask(for input: String) -> UInt32? {
        buttonMasks[input]
    }

    static func triggerAxis(for input: String) -> TriggerAxis? {
        triggerAxes[input]
    }

    static func isDigitalDirection(_ input: String) -> Bool {
        digitalDirections.contains(input)
    }

    static func isSpecialLocalInput(_ input: String) -> Bool {
        input == menuInput || input == toggleAnalogInput
    }

    static func thumbstickElement(for inputs: [String: String]) -> String {
        inputs.values.contains { $0.hasPrefix("rightThumbstick") } ?
            xboxRightThumbstick :
            xboxLeftThumbstick
    }
}

final class ManicSkinVirtualControllerBridge {
    private typealias SetTouchControllerState = @convention(c) (
        CInt,
        UInt32,
        Int16,
        Int16,
        Int16,
        Int16,
        Int16,
        Int16
    ) -> Void

    private var coreHandle: UnsafeMutableRawPointer?
    private var setTouchControllerState: SetTouchControllerState?
    private var activeDigitalDirections = Set<String>()
    private var activeButtonInputs = Set<String>()
    private var touchControlsActive = false
    private var leftTrigger: Int16 = 0
    private var rightTrigger: Int16 = 0
    private var leftThumbstick = CGPoint.zero
    private var rightThumbstick = CGPoint.zero
    private var didLogMissingCoreSymbol = false
    private let publishesToCore: Bool
    private var physicalController: GCController?
    private var physicalInputHandlersToRestore: [() -> Void] = []
    private var physicalInputState = CoreInputState(
        active: false,
        buttons: 0,
        leftTrigger: 0,
        rightTrigger: 0,
        leftX: 0,
        leftY: 0,
        rightX: 0,
        rightY: 0
    )
    private var lastPublishedState: CoreInputState?

    private struct CoreInputState: Equatable {
        var active: Bool
        var buttons: UInt32
        var leftTrigger: Int16
        var rightTrigger: Int16
        var leftX: Int16
        var leftY: Int16
        var rightX: Int16
        var rightY: Int16
    }

    init(publishesToCore: Bool = true) {
        self.publishesToCore = publishesToCore
    }

    func setTouchControlsActive(_ active: Bool) {
        NativeMetalDiagnostics.log("TOUCH_BRIDGE_ACTIVE", "active=\(active ? 1 : 0)")
        touchControlsActive = active
        if !active {
            resetLocalState()
        }
        publishState()
    }

    func hasPhysicalControllerConnected() -> Bool {
        GCController.controllers().contains { controller in
            if isVirtualController(controller) {
                return false
            }
            return controller.extendedGamepad != nil || controller.microGamepad != nil
        }
    }

    func isManagedVirtualController(_ controller: GCController) -> Bool {
        false
    }

    // Use per-element handlers rather than a timer. SDL keeps its own
    // profile-level handlers; this bridge chains and restores any handlers
    // already installed on individual GameController elements.
    func setPhysicalControllerInputEnabled(_ enabled: Bool) {
        guard publishesToCore else { return }
        let nextController = enabled ? connectedPhysicalController() : nil
        guard physicalController !== nextController else { return }

        restorePhysicalInputHandlers()
        physicalController = nextController

        if let nextController {
            physicalInputState = physicalState(nextController)
            installPhysicalInputHandlers(for: nextController)
            NativeMetalDiagnostics.log(
                "PHYSICAL_INPUT",
                "attached=1 device=\(nextController.vendorName ?? "unknown")"
            )
        } else {
            physicalInputState = CoreInputState(
                active: false,
                buttons: 0,
                leftTrigger: 0,
                rightTrigger: 0,
                leftX: 0,
                leftY: 0,
                rightX: 0,
                rightY: 0
            )
            NativeMetalDiagnostics.log("PHYSICAL_INPUT", "attached=0")
        }
        publishState()
    }

    private func connectedPhysicalController() -> GCController? {
        GCController.controllers().first { controller in
            !isVirtualController(controller) &&
                (controller.extendedGamepad != nil || controller.microGamepad != nil)
        }
    }

    private func restorePhysicalInputHandlers() {
        for restore in physicalInputHandlersToRestore.reversed() {
            restore()
        }
        physicalInputHandlersToRestore.removeAll(keepingCapacity: true)
    }

    private func installPhysicalInputHandlers(for controller: GCController) {
        if let pad = controller.extendedGamepad {
            installButtonHandler(pad.buttonA, mask: ManicSkinInputMapper.CoreButton.a)
            installButtonHandler(pad.buttonB, mask: ManicSkinInputMapper.CoreButton.b)
            installButtonHandler(pad.buttonX, mask: ManicSkinInputMapper.CoreButton.x)
            installButtonHandler(pad.buttonY, mask: ManicSkinInputMapper.CoreButton.y)
            installButtonHandler(pad.dpad.left, mask: ManicSkinInputMapper.CoreButton.dpadLeft)
            installButtonHandler(pad.dpad.up, mask: ManicSkinInputMapper.CoreButton.dpadUp)
            installButtonHandler(pad.dpad.right, mask: ManicSkinInputMapper.CoreButton.dpadRight)
            installButtonHandler(pad.dpad.down, mask: ManicSkinInputMapper.CoreButton.dpadDown)
            installButtonHandler(pad.buttonMenu, mask: ManicSkinInputMapper.CoreButton.start)
            if let options = pad.buttonOptions {
                installButtonHandler(options, mask: ManicSkinInputMapper.CoreButton.back)
            }
            installButtonHandler(pad.leftShoulder, mask: ManicSkinInputMapper.CoreButton.white)
            installButtonHandler(pad.rightShoulder, mask: ManicSkinInputMapper.CoreButton.black)
            if let leftThumb = pad.leftThumbstickButton {
                installButtonHandler(leftThumb, mask: ManicSkinInputMapper.CoreButton.leftThumb)
            }
            if let rightThumb = pad.rightThumbstickButton {
                installButtonHandler(rightThumb, mask: ManicSkinInputMapper.CoreButton.rightThumb)
            }
            installTriggerHandler(pad.leftTrigger, left: true)
            installTriggerHandler(pad.rightTrigger, left: false)
            installDirectionPadHandler(pad.leftThumbstick, left: true)
            installDirectionPadHandler(pad.rightThumbstick, left: false)
        } else if let pad = controller.microGamepad {
            installButtonHandler(pad.buttonA, mask: ManicSkinInputMapper.CoreButton.a)
            installButtonHandler(pad.buttonX, mask: ManicSkinInputMapper.CoreButton.x)
            installButtonHandler(pad.dpad.left, mask: ManicSkinInputMapper.CoreButton.dpadLeft)
            installButtonHandler(pad.dpad.up, mask: ManicSkinInputMapper.CoreButton.dpadUp)
            installButtonHandler(pad.dpad.right, mask: ManicSkinInputMapper.CoreButton.dpadRight)
            installButtonHandler(pad.dpad.down, mask: ManicSkinInputMapper.CoreButton.dpadDown)
        }
    }

    private func installButtonHandler(_ button: GCControllerButtonInput, mask: UInt32) {
        let previousHandler = button.valueChangedHandler
        button.valueChangedHandler = { [weak self] input, value, pressed in
            previousHandler?(input, value, pressed)
            guard let self else { return }
            if pressed {
                self.physicalInputState.buttons |= mask
            } else {
                self.physicalInputState.buttons &= ~mask
            }
            self.publishState()
        }
        physicalInputHandlersToRestore.append {
            button.valueChangedHandler = previousHandler
        }
    }

    private func installTriggerHandler(_ trigger: GCControllerButtonInput, left: Bool) {
        let previousHandler = trigger.valueChangedHandler
        trigger.valueChangedHandler = { [weak self] input, value, pressed in
            previousHandler?(input, value, pressed)
            guard let self else { return }
            let converted = self.triggerValue(value)
            if left {
                self.physicalInputState.leftTrigger = converted
            } else {
                self.physicalInputState.rightTrigger = converted
            }
            self.publishState()
        }
        physicalInputHandlersToRestore.append {
            trigger.valueChangedHandler = previousHandler
        }
    }

    private func installDirectionPadHandler(_ pad: GCControllerDirectionPad, left: Bool) {
        let previousHandler = pad.valueChangedHandler
        pad.valueChangedHandler = { [weak self] input, x, y in
            previousHandler?(input, x, y)
            guard let self else { return }
            if left {
                self.physicalInputState.leftX = self.axisValue(CGFloat(x))
                self.physicalInputState.leftY = self.axisValue(CGFloat(y))
            } else {
                self.physicalInputState.rightX = self.axisValue(CGFloat(x))
                self.physicalInputState.rightY = self.axisValue(CGFloat(y))
            }
            self.publishState()
        }
        physicalInputHandlersToRestore.append {
            pad.valueChangedHandler = previousHandler
        }
    }

    func setButtonInput(_ input: String, pressed: Bool) {
        if ManicSkinInputMapper.isSpecialLocalInput(input) {
            return
        }

        if ManicSkinInputMapper.isDigitalDirection(input) {
            setDigitalDirection(input, pressed: pressed)
            return
        }

        if let triggerAxis = ManicSkinInputMapper.triggerAxis(for: input) {
            setTrigger(triggerAxis, pressed: pressed)
            return
        }

        guard ManicSkinInputMapper.buttonMask(for: input) != nil else {
            return
        }

        if pressed {
            activeButtonInputs.insert(input)
        } else {
            activeButtonInputs.remove(input)
        }
        publishState()
    }

    func setThumbstick(element: String, position: CGPoint) {
        if element == ManicSkinInputMapper.xboxLeftThumbstick {
            leftThumbstick = position
        } else {
            rightThumbstick = position
        }
        publishState()
    }

    func resetThumbstick(element: String) {
        setThumbstick(element: element, position: .zero)
    }

    func releaseAllInputs() {
        resetLocalState()
        publishState()
    }

    private func setDigitalDirection(_ input: String, pressed: Bool) {
        if pressed {
            activeDigitalDirections.insert(input)
        } else {
            activeDigitalDirections.remove(input)
        }
        publishState()
    }

    private func setTrigger(_ triggerAxis: ManicSkinInputMapper.TriggerAxis, pressed: Bool) {
        let value: Int16 = pressed ? 32767 : 0
        switch triggerAxis {
        case .left:
            leftTrigger = value
        case .right:
            rightTrigger = value
        }
        publishState()
    }

    private func resetLocalState() {
        activeButtonInputs.removeAll()
        activeDigitalDirections.removeAll()
        leftTrigger = 0
        rightTrigger = 0
        leftThumbstick = .zero
        rightThumbstick = .zero
    }

    private func publishState() {
        guard publishesToCore else { return }
        let state = physicalController == nil ? CoreInputState(
            active: touchControlsActive,
            buttons: currentButtons,
            leftTrigger: leftTrigger,
            rightTrigger: rightTrigger,
            leftX: axisValue(leftThumbstick.x),
            leftY: axisValue(leftThumbstick.y),
            rightX: axisValue(rightThumbstick.x),
            rightY: axisValue(rightThumbstick.y)
        ) : physicalInputState
        guard state != lastPublishedState,
              let setter = resolveSetTouchControllerState() else { return }

        lastPublishedState = state
        setter(
            state.active ? 1 : 0,
            state.buttons,
            state.leftTrigger,
            state.rightTrigger,
            state.leftX,
            state.leftY,
            state.rightX,
            state.rightY
        )
    }

    private func physicalState(_ controller: GCController) -> CoreInputState {
        var buttons: UInt32 = 0
        func add(_ pressed: Bool, mask: UInt32) {
            if pressed { buttons |= mask }
        }

        if let pad = controller.extendedGamepad {
            add(pad.buttonA.isPressed, mask: ManicSkinInputMapper.CoreButton.a)
            add(pad.buttonB.isPressed, mask: ManicSkinInputMapper.CoreButton.b)
            add(pad.buttonX.isPressed, mask: ManicSkinInputMapper.CoreButton.x)
            add(pad.buttonY.isPressed, mask: ManicSkinInputMapper.CoreButton.y)
            add(pad.dpad.left.isPressed, mask: ManicSkinInputMapper.CoreButton.dpadLeft)
            add(pad.dpad.up.isPressed, mask: ManicSkinInputMapper.CoreButton.dpadUp)
            add(pad.dpad.right.isPressed, mask: ManicSkinInputMapper.CoreButton.dpadRight)
            add(pad.dpad.down.isPressed, mask: ManicSkinInputMapper.CoreButton.dpadDown)
            add(pad.buttonMenu.isPressed, mask: ManicSkinInputMapper.CoreButton.start)
            add(pad.buttonOptions?.isPressed == true, mask: ManicSkinInputMapper.CoreButton.back)
            add(pad.leftShoulder.isPressed, mask: ManicSkinInputMapper.CoreButton.white)
            add(pad.rightShoulder.isPressed, mask: ManicSkinInputMapper.CoreButton.black)
            add(pad.leftThumbstickButton?.isPressed == true, mask: ManicSkinInputMapper.CoreButton.leftThumb)
            add(pad.rightThumbstickButton?.isPressed == true, mask: ManicSkinInputMapper.CoreButton.rightThumb)
            return CoreInputState(
                active: true,
                buttons: buttons,
                leftTrigger: triggerValue(pad.leftTrigger.value),
                rightTrigger: triggerValue(pad.rightTrigger.value),
                leftX: axisValue(CGFloat(pad.leftThumbstick.xAxis.value)),
                leftY: axisValue(CGFloat(pad.leftThumbstick.yAxis.value)),
                rightX: axisValue(CGFloat(pad.rightThumbstick.xAxis.value)),
                rightY: axisValue(CGFloat(pad.rightThumbstick.yAxis.value))
            )
        }

        if let pad = controller.microGamepad {
            add(pad.buttonA.isPressed, mask: ManicSkinInputMapper.CoreButton.a)
            add(pad.buttonX.isPressed, mask: ManicSkinInputMapper.CoreButton.x)
            add(pad.dpad.left.isPressed, mask: ManicSkinInputMapper.CoreButton.dpadLeft)
            add(pad.dpad.up.isPressed, mask: ManicSkinInputMapper.CoreButton.dpadUp)
            add(pad.dpad.right.isPressed, mask: ManicSkinInputMapper.CoreButton.dpadRight)
            add(pad.dpad.down.isPressed, mask: ManicSkinInputMapper.CoreButton.dpadDown)
        }
        return CoreInputState(
            active: true, buttons: buttons,
            leftTrigger: 0, rightTrigger: 0,
            leftX: 0, leftY: 0, rightX: 0, rightY: 0
        )
    }

    private func triggerValue(_ value: Float) -> Int16 {
        Int16((max(0, min(1, value)) * 32767).rounded())
    }

    private var currentButtons: UInt32 {
        var buttons: UInt32 = 0
        for input in activeButtonInputs {
            buttons |= ManicSkinInputMapper.buttonMask(for: input) ?? 0
        }
        if activeDigitalDirections.contains("left") {
            buttons |= ManicSkinInputMapper.CoreButton.dpadLeft
        }
        if activeDigitalDirections.contains("up") {
            buttons |= ManicSkinInputMapper.CoreButton.dpadUp
        }
        if activeDigitalDirections.contains("right") {
            buttons |= ManicSkinInputMapper.CoreButton.dpadRight
        }
        if activeDigitalDirections.contains("down") {
            buttons |= ManicSkinInputMapper.CoreButton.dpadDown
        }
        return buttons
    }

    private func axisValue(_ value: CGFloat) -> Int16 {
        let clamped = max(-1, min(1, value))
        let scaled = clamped >= 0 ? clamped * 32767 : clamped * 32768
        let rounded = Int(scaled.rounded())
        return Int16(max(-32768, min(32767, rounded)))
    }

    private func resolveSetTouchControllerState() -> SetTouchControllerState? {
        if let setTouchControllerState {
            return setTouchControllerState
        }

        guard let frameworksURL = Bundle.main.privateFrameworksURL else {
            logMissingCoreSymbol("missing private frameworks URL")
            return nil
        }

        let coreURL = frameworksURL.appendingPathComponent("libxemu-ios-core.dylib")
        guard let handle = dlopen(coreURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let errorMessage = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            logMissingCoreSymbol(errorMessage)
            return nil
        }

        guard let symbol = dlsym(handle, "xemu_ios_set_touch_controller_state") else {
            logMissingCoreSymbol("xemu_ios_set_touch_controller_state is unavailable")
            return nil
        }

        coreHandle = handle
        let setter = unsafeBitCast(symbol, to: SetTouchControllerState.self)
        setTouchControllerState = setter
        NativeMetalDiagnostics.log("TOUCH_BRIDGE_SYMBOL", "resolved=1")
        return setter
    }

    private func logMissingCoreSymbol(_ message: String) {
        guard !didLogMissingCoreSymbol else {
            return
        }

        didLogMissingCoreSymbol = true
        NSLog("Manic skin core input bridge unavailable: %@", message)
        NativeMetalDiagnostics.log("TOUCH_BRIDGE_SYMBOL", "resolved=0 message=\(message)")
    }

    private func isVirtualController(_ controller: GCController) -> Bool {
        let vendorName = controller.vendorName ?? ""
        return vendorName.localizedCaseInsensitiveContains("virtual") ||
            controller.productCategory.localizedCaseInsensitiveContains("virtual")
    }
}
