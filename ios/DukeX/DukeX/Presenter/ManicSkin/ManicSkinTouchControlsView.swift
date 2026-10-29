import CoreHaptics
import GameController
import QuartzCore
import UIKit

final class ManicSkinTouchControlsView: UIView {
    var onMenuRequested: (() -> Void)?
    var onGameViewportFrameChanged: ((CGRect?) -> Void)?
    var onTouchControlsModeChanged: ((Bool) -> Void)?

    var isTouchSkinActive: Bool {
        touchControlsActive && !isHidden && alpha > 0.01
    }

    var activeGameViewportFrame: CGRect? {
        isTouchSkinActive ? resolvedRepresentation?.screenFrame : nil
    }

    private(set) var lastDirectTouchDeliveryTime: CFTimeInterval = 0

    private let skin: ManicSkin
    private let portraitSkin: ManicSkin?
    private let landscapeSkin: ManicSkin?
    private let previewMode: Bool
    private let previewOrientation: ManicSkinPreviewOrientation?
    private let controllerBridge: ManicSkinVirtualControllerBridge
    private let hapticFeedbackPerformer = TouchHapticFeedbackPerformer.shared
    private let backgroundImageView = UIImageView()
    private var itemImageViews: [Int: UIImageView] = [:]
    private var resolvedRepresentation: ManicSkinResolvedRepresentation?
    private var lastLayoutSignature = ""
    private var controllerObservers: [NSObjectProtocol] = []
    private var activeTouches: [TouchTrackingKey: ActiveTouch] = [:]
    private var touchControlsActive = false

    init?(
        skin: ManicSkin? = ManicSkin.bundledDefault(),
        portraitSkin: ManicSkin? = nil,
        landscapeSkin: ManicSkin? = nil,
        previewMode: Bool = false,
        previewOrientation: ManicSkinPreviewOrientation? = nil
    ) {
        guard let skin = skin ?? portraitSkin ?? landscapeSkin else {
            return nil
        }
        self.skin = skin
        self.portraitSkin = portraitSkin
        self.landscapeSkin = landscapeSkin
        self.previewMode = previewMode
        self.previewOrientation = previewOrientation
        self.controllerBridge = ManicSkinVirtualControllerBridge(publishesToCore: !previewMode)
        super.init(frame: .zero)
        configureView()
    }

    required init?(coder: NSCoder) {
        guard let skin = ManicSkin.bundledDefault() else {
            return nil
        }
        self.skin = skin
        self.portraitSkin = nil
        self.landscapeSkin = nil
        self.previewMode = false
        self.previewOrientation = nil
        self.controllerBridge = ManicSkinVirtualControllerBridge()
        super.init(coder: coder)
        configureView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        NativeMetalDiagnostics.log(
            "SKIN_WINDOW",
            "window=\(NativeMetalDiagnostics.objectID(window)) bounds=\(NativeMetalDiagnostics.rect(bounds)) hidden=\(isHidden ? 1 : 0) active=\(touchControlsActive ? 1 : 0)"
        )
        if window == nil {
            stopControllerObservers()
            releaseAllTouches()
            touchControlsActive = false
            isHidden = true
            isUserInteractionEnabled = false
            controllerBridge.setPhysicalControllerInputEnabled(false)
            controllerBridge.setTouchControlsActive(false)
            onTouchControlsModeChanged?(false)
            notifyViewportChanged()
        } else {
            startControllerObservers()
            updateControllerMode(reason: "window")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildLayoutIfNeeded()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard touchControlsActive,
              !isHidden,
              alpha > 0.01,
              let resolvedRepresentation else {
            NativeMetalDiagnostics.log(
                "SKIN_POINT_INSIDE",
                "point=\(NativeMetalDiagnostics.point(point)) hit=0 inactive=1 active=\(touchControlsActive ? 1 : 0) hidden=\(isHidden ? 1 : 0) alpha=\(String(format: "%.2f", alpha)) resolved=\(self.resolvedRepresentation == nil ? 0 : 1)"
            )
            return false
        }

        let hit = resolvedRepresentation.items.contains { effectiveHitFrame(for: $0).contains(point) }
        NativeMetalDiagnostics.log(
            "SKIN_POINT_INSIDE",
            "point=\(NativeMetalDiagnostics.point(point)) hit=\(hit ? 1 : 0) key=\(resolvedRepresentation.key) bounds=\(NativeMetalDiagnostics.rect(bounds))"
        )
        return hit
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if event?.type == .touches {
            let resultName = result.map { "\(type(of: $0))#\(NativeMetalDiagnostics.objectID($0))" } ?? "nil"
            NativeMetalDiagnostics.log(
                "SKIN_HIT_TEST",
                "point=\(NativeMetalDiagnostics.point(point)) result=\(resultName) active=\(touchControlsActive ? 1 : 0) hidden=\(isHidden ? 1 : 0) bounds=\(NativeMetalDiagnostics.rect(bounds))"
            )
        }
        return result
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        markDirectTouchDelivery()
        NativeMetalDiagnostics.log(
            "SKIN_UIKIT_TOUCHES_BEGAN",
            "count=\(touches.count) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: self) }.joined(separator: " | "))"
        )
        for touch in touches {
            beginTracking(touch)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        markDirectTouchDelivery()
        NativeMetalDiagnostics.log(
            "SKIN_UIKIT_TOUCHES_MOVED",
            "count=\(touches.count) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: self) }.joined(separator: " | "))"
        )
        for touch in touches {
            updateTracking(touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        markDirectTouchDelivery()
        NativeMetalDiagnostics.log(
            "SKIN_UIKIT_TOUCHES_ENDED",
            "count=\(touches.count) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: self) }.joined(separator: " | "))"
        )
        for touch in touches {
            endTracking(touch, cancelled: false)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        markDirectTouchDelivery()
        NativeMetalDiagnostics.log(
            "SKIN_UIKIT_TOUCHES_CANCELLED",
            "count=\(touches.count) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: self) }.joined(separator: " | "))"
        )
        for touch in touches {
            endTracking(touch, cancelled: true)
        }
    }

    private func markDirectTouchDelivery() {
        lastDirectTouchDeliveryTime = CACurrentMediaTime()
    }

    func refreshLayoutForGeometryChange(forceRebuild: Bool = false) {
        NativeMetalDiagnostics.log(
            "SKIN_REFRESH_LAYOUT",
            "force=\(forceRebuild ? 1 : 0) bounds=\(NativeMetalDiagnostics.rect(bounds)) safe=\(NativeMetalDiagnostics.insets(safeAreaInsets)) signature=\(lastLayoutSignature)"
        )
        guard hasUsableLayoutBounds else {
            NativeMetalDiagnostics.log(
                "SKIN_REFRESH_LAYOUT_SKIP",
                "reason=invalid-bounds force=\(forceRebuild ? 1 : 0) bounds=\(NativeMetalDiagnostics.rect(bounds)) signature=\(lastLayoutSignature)"
            )
            return
        }
        if forceRebuild {
            releaseAllTouches()
            lastLayoutSignature = ""
        }
        setNeedsLayout()
        layoutIfNeeded()
        notifyViewportChanged()
    }

    @discardableResult
    func handleBridgedTouch(
        phase: NativeGameplayTouchPhase,
        id: Int64,
        point: CGPoint
    ) -> Bool {
        let key = TouchTrackingKey.bridged(id)
        switch phase {
        case .began:
            return beginTracking(key: key, point: point)
        case .moved:
            return updateTracking(key: key, point: point)
        case .ended:
            return endTracking(key: key, cancelled: false)
        case .cancelled:
            return endTracking(key: key, cancelled: true)
        }
    }

    func fallbackTarget(at point: CGPoint) -> ManicSkinFallbackTarget? {
        guard let item = item(at: point) else {
            return nil
        }

        let isThumbstick: Bool
        switch item.kind {
        case .buttons, .directionalPad:
            isThumbstick = false
        case .thumbstick:
            isThumbstick = true
        }

        return ManicSkinFallbackTarget(
            itemID: item.id,
            isThumbstick: isThumbstick,
            description: describeItem(item)
        )
    }

    func boostedFallbackThumbstickPoint(
        for itemID: Int,
        at point: CGPoint,
        minimumNormalizedDistance: CGFloat = 0.72
    ) -> CGPoint? {
        guard let item = resolvedRepresentation?.items.first(where: { $0.id == itemID }),
              case .thumbstick = item.kind else {
            return nil
        }

        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let radius = max(min(item.frame.width, item.frame.height) * 0.5, 1)
        var dx = (point.x - center.x) / radius
        var dy = (point.y - center.y) / radius
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.001 else {
            NativeMetalDiagnostics.log(
                "SKIN_THUMBSTICK_FALLBACK_BOOST",
                "item=\(item.id) raw=\(NativeMetalDiagnostics.point(point)) adjusted=\(NativeMetalDiagnostics.point(point)) length=0.000"
            )
            return point
        }

        let minimumDistance = max(0, min(1, minimumNormalizedDistance))
        if length > 1 {
            dx /= length
            dy /= length
        } else if length < minimumDistance {
            let scale = minimumDistance / length
            dx *= scale
            dy *= scale
        }

        let adjustedPoint = CGPoint(
            x: center.x + dx * radius,
            y: center.y + dy * radius
        )
        NativeMetalDiagnostics.log(
            "SKIN_THUMBSTICK_FALLBACK_BOOST",
            "item=\(item.id) raw=\(NativeMetalDiagnostics.point(point)) adjusted=\(NativeMetalDiagnostics.point(adjustedPoint)) length=\(String(format: "%.3f", length)) minimum=\(String(format: "%.3f", minimumDistance))"
        )
        return adjustedPoint
    }

    func hasActiveBridgedTouch(id: Int64) -> Bool {
        activeTouches[.bridged(id)] != nil
    }

    @discardableResult
    func handleRawTouch(_ touch: UITouch) -> Bool {
        handleExternalTouch(touch, at: touch.location(in: self))
    }

    @discardableResult
    func handleExternalTouch(_ touch: UITouch, at point: CGPoint) -> Bool {
        let key = TouchTrackingKey.ui(ObjectIdentifier(touch))
        let shouldLog = touch.phase != .moved || activeTouches[key] == nil

        let handled: Bool
        switch touch.phase {
        case .began:
            handled = beginTracking(key: key, point: point)
        case .moved:
            handled = updateTracking(key: key, point: point)
        case .ended:
            handled = endTracking(key: key, cancelled: false)
        case .cancelled:
            handled = endTracking(key: key, cancelled: true)
        case .stationary, .regionEntered, .regionMoved, .regionExited:
            handled = activeTouches[key] != nil
        @unknown default:
            handled = false
        }
        if shouldLog || !handled {
            NativeMetalDiagnostics.log(
                "SKIN_EXTERNAL_TOUCH",
                "phase=\(NativeMetalDiagnostics.phaseName(touch.phase)) point=\(NativeMetalDiagnostics.point(point)) handled=\(handled ? 1 : 0) activeTouches=\(activeTouches.count) key=\(resolvedRepresentation?.key ?? "nil")"
            )
        }
        return handled
    }

    private func configureView() {
        backgroundColor = .clear
        isHidden = true
        isUserInteractionEnabled = false
        isMultipleTouchEnabled = true
        isExclusiveTouch = false

        backgroundImageView.contentMode = .scaleToFill
        backgroundImageView.isUserInteractionEnabled = false
        addSubview(backgroundImageView)
    }

    private func startControllerObservers() {
        guard controllerObservers.isEmpty else {
            return
        }

        controllerObservers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let controller = notification.object as? GCController,
               self.controllerBridge.isManagedVirtualController(controller) {
                return
            }
            self.updateControllerMode(reason: "controller-connect")
        })

        controllerObservers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let controller = notification.object as? GCController,
               self.controllerBridge.isManagedVirtualController(controller) {
                return
            }
            self.updateControllerMode(reason: "controller-disconnect")
        })
    }

    private func stopControllerObservers() {
        for observer in controllerObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        controllerObservers.removeAll()
    }

    private func updateControllerMode(reason: String) {
        let shouldUseTouchControls = previewMode || !controllerBridge.hasPhysicalControllerConnected()
        let modeChanged = shouldUseTouchControls != touchControlsActive
        let wasActive = isTouchSkinActive
        NativeMetalDiagnostics.log(
            "SKIN_MODE",
            "reason=\(reason) shouldUse=\(shouldUseTouchControls ? 1 : 0) modeChanged=\(modeChanged ? 1 : 0) wasActive=\(wasActive ? 1 : 0) controllers=\(GCController.controllers().count)"
        )

        touchControlsActive = shouldUseTouchControls
        isHidden = !shouldUseTouchControls
        isUserInteractionEnabled = shouldUseTouchControls
        if shouldUseTouchControls {
            // Keep port 1 alive while handing the game back to touch.
            if modeChanged {
                controllerBridge.setTouchControlsActive(true)
                NSLog("Manic skin touch controls shown (%@)", reason)
            }
            controllerBridge.setPhysicalControllerInputEnabled(false)
        } else {
            releaseAllTouches()
            // SDL may miss mid-game hotplug. Forward physical input through
            // the existing native Xbox controller bridge.
            controllerBridge.setPhysicalControllerInputEnabled(true)
            if modeChanged {
                controllerBridge.setTouchControlsActive(false)
                NSLog("Manic skin touch controls hidden because a physical controller is connected (%@)", reason)
            }
        }
        if modeChanged || wasActive != isTouchSkinActive {
            onTouchControlsModeChanged?(isTouchSkinActive)
        }
        notifyViewportChanged()
    }

    private func rebuildLayoutIfNeeded() {
        guard hasUsableLayoutBounds else {
            NativeMetalDiagnostics.log(
                "SKIN_REBUILD_SKIP",
                "reason=invalid-bounds bounds=\(NativeMetalDiagnostics.rect(bounds)) signature=\(lastLayoutSignature)"
            )
            return
        }

        let interfaceOrientation = previewOrientation?.interfaceOrientation ?? window?.windowScene?.interfaceOrientation
        let orientationValue = interfaceOrientation?.rawValue ?? 0
        let activeSkin = skin(for: interfaceOrientation)
        let styleReferenceBounds = previewMode ? (window?.screen.bounds ?? UIScreen.main.bounds) : nil
        let styleReferenceSafeAreaInsets = previewMode ? (window?.safeAreaInsets ?? .zero) : nil
        let styleReferenceSignature = [
            styleReferenceBounds.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" } ?? "runtime",
            styleReferenceSafeAreaInsets.map(NativeMetalDiagnostics.insets) ?? "runtime"
        ].joined(separator: "-")
        let signature = "\(activeSkin.baseURL.path)-\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded()))-\(safeAreaInsets)-\(traitCollection.userInterfaceIdiom.rawValue)-\(orientationValue)-\(styleReferenceSignature)"
        guard signature != lastLayoutSignature else {
            return
        }

        NativeMetalDiagnostics.log(
            "SKIN_REBUILD_START",
            "old=\(lastLayoutSignature) new=\(signature) bounds=\(NativeMetalDiagnostics.rect(bounds)) safe=\(NativeMetalDiagnostics.insets(safeAreaInsets)) orientation=\(orientationValue)"
        )
        lastLayoutSignature = signature
        guard let resolvedRepresentation = activeSkin.resolvedRepresentation(
            in: bounds,
            safeAreaInsets: safeAreaInsets,
            traitCollection: traitCollection,
            interfaceOrientation: interfaceOrientation,
            styleReferenceBounds: styleReferenceBounds,
            styleReferenceSafeAreaInsets: styleReferenceSafeAreaInsets
        ) else {
            self.resolvedRepresentation = nil
            backgroundImageView.image = nil
            clearItemViews()
            notifyViewportChanged()
            NativeMetalDiagnostics.log("SKIN_REBUILD_RESULT", "resolved=0")
            return
        }

        self.resolvedRepresentation = resolvedRepresentation
        backgroundImageView.frame = resolvedRepresentation.skinFrame
        backgroundImageView.image = resolvedRepresentation.background.flatMap {
            ManicSkinPDFRenderer.image(
                for: $0,
                targetSize: resolvedRepresentation.skinFrame.size,
                scale: window?.screen.scale ?? UIScreen.main.scale
            )
        }

        rebuildItemViews(for: resolvedRepresentation)
        notifyViewportChanged()
        NativeMetalDiagnostics.log(
            "SKIN_REBUILD_RESULT",
            "resolved=1 key=\(resolvedRepresentation.key) skin=\(NativeMetalDiagnostics.rect(resolvedRepresentation.skinFrame)) screen=\(NativeMetalDiagnostics.rect(resolvedRepresentation.screenFrame ?? .zero)) items=\(resolvedRepresentation.items.count) samples=\(resolvedRepresentation.items.prefix(6).map { describeItem($0) }.joined(separator: " | "))"
        )
    }

    private func skin(for interfaceOrientation: UIInterfaceOrientation?) -> ManicSkin {
        switch interfaceOrientation {
        case .landscapeLeft, .landscapeRight:
            return landscapeSkin ?? skin
        case .portrait, .portraitUpsideDown:
            return portraitSkin ?? skin
        default:
            return bounds.width > bounds.height ? (landscapeSkin ?? skin) : (portraitSkin ?? skin)
        }
    }

    private var hasUsableLayoutBounds: Bool {
        bounds.width > 1 && bounds.height > 1
    }

    private func rebuildItemViews(for representation: ManicSkinResolvedRepresentation) {
        clearItemViews()

        let scale = window?.screen.scale ?? UIScreen.main.scale
        for item in representation.items {
            guard let asset = item.asset else {
                continue
            }
            let imageView = UIImageView(frame: item.visualFrame)
            imageView.contentMode = .scaleToFill
            imageView.isUserInteractionEnabled = false
            imageView.alpha = 0.94
            imageView.image = ManicSkinPDFRenderer.image(
                for: asset,
                targetSize: item.visualFrame.size,
                scale: scale
            )
            addSubview(imageView)
            itemImageViews[item.id] = imageView
        }
    }

    private func clearItemViews() {
        for imageView in itemImageViews.values {
            imageView.removeFromSuperview()
        }
        itemImageViews.removeAll()
    }

    private func beginTracking(_ touch: UITouch) {
        _ = beginTracking(
            key: .ui(ObjectIdentifier(touch)),
            point: touch.location(in: self)
        )
    }

    @discardableResult
    private func beginTracking(key: TouchTrackingKey, point: CGPoint) -> Bool {
        guard touchControlsActive,
              !isHidden,
              alpha > 0.01 else {
            NativeMetalDiagnostics.log(
                "SKIN_BEGIN_FAIL",
                "reason=inactive point=\(NativeMetalDiagnostics.point(point)) active=\(touchControlsActive ? 1 : 0) hidden=\(isHidden ? 1 : 0) alpha=\(String(format: "%.2f", alpha))"
            )
            return false
        }
        guard let item = item(at: point) else {
            NativeMetalDiagnostics.log(
                "SKIN_BEGIN_FAIL",
                "reason=no-item point=\(NativeMetalDiagnostics.point(point)) key=\(resolvedRepresentation?.key ?? "nil") bounds=\(NativeMetalDiagnostics.rect(bounds)) items=\(resolvedRepresentation?.items.count ?? 0)"
            )
            return false
        }

        let activeTouch = ActiveTouch(item: item)
        NativeMetalDiagnostics.log(
            "SKIN_BEGIN",
            "point=\(NativeMetalDiagnostics.point(point)) item=\(describeItem(item)) activeTouches=\(activeTouches.count)"
        )
        switch item.kind {
        case .buttons(let inputs):
            activeTouches[key] = activeTouch
            for input in inputs {
                controllerBridge.setButtonInput(input, pressed: true)
            }
            playTouchHaptic()
            setItemPressed(item.id, pressed: true)
        case .directionalPad:
            activeTouches[key] = activeTouch
            updateDirectionalPad(item: item, key: key, point: point)
        case .thumbstick(let element):
            activeTouches[key] = activeTouch
            playTouchHaptic()
            updateThumbstick(item: item, element: element, point: point)
        }
        return true
    }

    private func updateTracking(_ touch: UITouch) {
        _ = updateTracking(
            key: .ui(ObjectIdentifier(touch)),
            point: touch.location(in: self)
        )
    }

    @discardableResult
    private func updateTracking(key: TouchTrackingKey, point: CGPoint) -> Bool {
        guard let activeTouch = activeTouches[key] else {
            return false
        }

        switch activeTouch.item.kind {
        case .buttons:
            break
        case .directionalPad:
            updateDirectionalPad(item: activeTouch.item, key: key, point: point)
        case .thumbstick(let element):
            updateThumbstick(item: activeTouch.item, element: element, point: point)
        }
        return true
    }

    private func endTracking(_ touch: UITouch, cancelled: Bool) {
        _ = endTracking(key: .ui(ObjectIdentifier(touch)), cancelled: cancelled)
    }

    @discardableResult
    private func endTracking(key: TouchTrackingKey, cancelled: Bool) -> Bool {
        guard let activeTouch = activeTouches.removeValue(forKey: key) else {
            NativeMetalDiagnostics.log(
                "SKIN_END_MISS",
                "cancelled=\(cancelled ? 1 : 0) activeTouches=\(activeTouches.count)"
            )
            return false
        }

        NativeMetalDiagnostics.log(
            "SKIN_END",
            "cancelled=\(cancelled ? 1 : 0) item=\(describeItem(activeTouch.item)) activeTouches=\(activeTouches.count)"
        )
        switch activeTouch.item.kind {
        case .buttons(let inputs):
            for input in inputs {
                if isInputStillActive(input) {
                    NativeMetalDiagnostics.log(
                        "SKIN_INPUT_RELEASE_DEFER",
                        "input=\(input) reason=still-held activeTouches=\(activeTouches.count)"
                    )
                } else {
                    controllerBridge.setButtonInput(input, pressed: false)
                }
            }
            if isItemStillActive(activeTouch.item.id) {
                NativeMetalDiagnostics.log(
                    "SKIN_ITEM_VISUAL_RELEASE_DEFER",
                    "item=\(activeTouch.item.id) reason=still-held activeTouches=\(activeTouches.count)"
                )
            } else {
                setItemPressed(activeTouch.item.id, pressed: false)
            }
            if !cancelled,
               inputs.contains(ManicSkinInputMapper.menuInput),
               !isInputStillActive(ManicSkinInputMapper.menuInput) {
                onMenuRequested?()
            }
        case .directionalPad:
            for input in activeTouch.directionalInputs {
                if isInputStillActive(input) {
                    NativeMetalDiagnostics.log(
                        "SKIN_INPUT_RELEASE_DEFER",
                        "input=\(input) reason=still-held activeTouches=\(activeTouches.count)"
                    )
                } else {
                    controllerBridge.setButtonInput(input, pressed: false)
                }
            }
            if isItemStillActive(activeTouch.item.id) {
                NativeMetalDiagnostics.log(
                    "SKIN_ITEM_VISUAL_RELEASE_DEFER",
                    "item=\(activeTouch.item.id) reason=still-held activeTouches=\(activeTouches.count)"
                )
            } else {
                setItemPressed(activeTouch.item.id, pressed: false)
            }
        case .thumbstick(let element):
            if isThumbstickElementStillActive(element) {
                NativeMetalDiagnostics.log(
                    "SKIN_THUMBSTICK_RELEASE_DEFER",
                    "element=\(element) reason=still-held activeTouches=\(activeTouches.count)"
                )
            } else {
                controllerBridge.resetThumbstick(element: element)
            }
            if isItemStillActive(activeTouch.item.id) {
                NativeMetalDiagnostics.log(
                    "SKIN_ITEM_VISUAL_RELEASE_DEFER",
                    "item=\(activeTouch.item.id) reason=still-held activeTouches=\(activeTouches.count)"
                )
            } else {
                resetThumbstickVisual(activeTouch.item.id)
            }
        }
        return true
    }

    private func releaseAllTouches() {
        if activeTouches.isEmpty == false {
            NativeMetalDiagnostics.log("SKIN_RELEASE_ALL", "count=\(activeTouches.count)")
        }
        for activeTouch in activeTouches.values {
            switch activeTouch.item.kind {
            case .buttons, .directionalPad:
                setItemPressed(activeTouch.item.id, pressed: false)
            case .thumbstick:
                resetThumbstickVisual(activeTouch.item.id)
            }
        }
        activeTouches.removeAll()
        controllerBridge.releaseAllInputs()
    }

    private func updateDirectionalPad(item: ManicSkinResolvedItem, key: TouchTrackingKey, point: CGPoint) {
        let previousInputs = activeTouches[key]?.directionalInputs ?? []
        let nextInputs = directionalPadInputs(for: item, point: point)
        activeTouches[key] = ActiveTouch(item: item, directionalInputs: nextInputs)

        let newlyPressedInputs = nextInputs.subtracting(previousInputs)
        for input in newlyPressedInputs {
            controllerBridge.setButtonInput(input, pressed: true)
        }

        for input in previousInputs.subtracting(nextInputs) where !isInputStillActive(input) {
            controllerBridge.setButtonInput(input, pressed: false)
        }

        if !newlyPressedInputs.isEmpty {
            playTouchHaptic()
        }

        setItemPressed(item.id, pressed: !nextInputs.isEmpty)
        NativeMetalDiagnostics.log(
            "SKIN_DPAD_UPDATE",
            "item=\(item.id) point=\(NativeMetalDiagnostics.point(point)) inputs=\(nextInputs.sorted().joined(separator: ","))"
        )
    }

    private func directionalPadInputs(for item: ManicSkinResolvedItem, point: CGPoint) -> Set<String> {
        guard case .directionalPad(let directionalInputs) = item.kind else {
            return []
        }

        let horizontalRadius = max(item.frame.width * 0.5, 1)
        let verticalRadius = max(item.frame.height * 0.5, 1)
        let horizontal = (point.x - item.frame.midX) / horizontalRadius
        let vertical = (point.y - item.frame.midY) / verticalRadius
        let threshold: CGFloat = 0.28

        var activeInputs = Set<String>()
        for directionalInput in directionalInputs {
            switch directionalInput.direction {
            case .up where vertical <= -threshold:
                activeInputs.insert(directionalInput.input)
            case .down where vertical >= threshold:
                activeInputs.insert(directionalInput.input)
            case .left where horizontal <= -threshold:
                activeInputs.insert(directionalInput.input)
            case .right where horizontal >= threshold:
                activeInputs.insert(directionalInput.input)
            default:
                break
            }
        }
        return activeInputs
    }

    private func playTouchHaptic() {
        hapticFeedbackPerformer.play()
    }

    private func updateThumbstick(item: ManicSkinResolvedItem, element: String, point: CGPoint) {
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let radius = max(min(item.frame.width, item.frame.height) * 0.5, 1)
        var x = (point.x - center.x) / radius
        var y = -(point.y - center.y) / radius
        let length = sqrt(x * x + y * y)
        if length > 1 {
            x /= length
            y /= length
        }
        if abs(x) < 0.1 {
            x = 0
        }
        if abs(y) < 0.1 {
            y = 0
        }

        let position = CGPoint(x: x, y: y)
        NativeMetalDiagnostics.log(
            "SKIN_THUMBSTICK_UPDATE",
            "item=\(item.id) element=\(element) point=\(NativeMetalDiagnostics.point(point)) position=\(NativeMetalDiagnostics.point(position))"
        )
        controllerBridge.setThumbstick(element: element, position: position)
        setThumbstickVisual(item, position: position, radius: radius)
    }

    private func item(at point: CGPoint) -> ManicSkinResolvedItem? {
        resolvedRepresentation?.items
            .filter { effectiveHitFrame(for: $0).contains(point) }
            .min { lhs, rhs in
                let lhsFrame = effectiveHitFrame(for: lhs)
                let rhsFrame = effectiveHitFrame(for: rhs)
                return lhsFrame.width * lhsFrame.height < rhsFrame.width * rhsFrame.height
            }
    }

    private func isInputStillActive(_ input: String) -> Bool {
        activeTouches.values.contains { activeTouch in
            switch activeTouch.item.kind {
            case .buttons(let inputs):
                return inputs.contains(input)
            case .directionalPad:
                return activeTouch.directionalInputs.contains(input)
            case .thumbstick:
                return false
            }
        }
    }

    private func isThumbstickElementStillActive(_ element: String) -> Bool {
        activeTouches.values.contains { activeTouch in
            guard case .thumbstick(let activeElement) = activeTouch.item.kind else {
                return false
            }
            return activeElement == element
        }
    }

    private func isItemStillActive(_ itemID: Int) -> Bool {
        activeTouches.values.contains { $0.item.id == itemID }
    }

    private func effectiveHitFrame(for item: ManicSkinResolvedItem) -> CGRect {
        switch item.kind {
        case .buttons, .directionalPad:
            return item.hitFrame
        case .thumbstick:
            return item.frame
        }
    }

    private func describeItem(_ item: ManicSkinResolvedItem) -> String {
        let kind: String
        switch item.kind {
        case .buttons(let inputs):
            kind = "buttons:\(inputs.joined(separator: ","))"
        case .directionalPad(let directionalInputs):
            let inputs = directionalInputs.map { "\($0.direction.rawValue)=\($0.input)" }.joined(separator: ",")
            kind = "dpad:\(inputs)"
        case .thumbstick(let element):
            kind = "thumbstick:\(element)"
        }
        return "id=\(item.id) kind=\(kind) frame=\(NativeMetalDiagnostics.rect(item.frame)) visual=\(NativeMetalDiagnostics.rect(item.visualFrame)) hit=\(NativeMetalDiagnostics.rect(item.hitFrame))"
    }

    private func setItemPressed(_ itemID: Int, pressed: Bool) {
        guard let imageView = itemImageViews[itemID] else {
            return
        }

        UIView.animate(withDuration: 0.08) {
            imageView.alpha = pressed ? 0.58 : 0.94
            imageView.transform = pressed ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
        }
    }

    private func setThumbstickVisual(_ item: ManicSkinResolvedItem, position: CGPoint, radius: CGFloat) {
        guard let imageView = itemImageViews[item.id] else {
            return
        }

        let travel = thumbstickVisualTravel(for: item, radius: radius)
        imageView.alpha = 0.74
        imageView.transform = CGAffineTransform(
            translationX: position.x * travel,
            y: -position.y * travel
        )
    }

    private func thumbstickVisualTravel(for item: ManicSkinResolvedItem, radius: CGFloat) -> CGFloat {
        let controlDiameter = min(item.frame.width, item.frame.height)
        let visualDiameter = min(item.visualFrame.width, item.visualFrame.height)
        let legacyTravel = radius * 0.22
        guard controlDiameter > 1, visualDiameter > 1 else {
            return legacyTravel
        }

        let visualRatio = visualDiameter / controlDiameter
        guard visualRatio < 0.75 else {
            return legacyTravel
        }

        let containedTravel = max((controlDiameter - visualDiameter) * 0.5, 0)
        return max(containedTravel, legacyTravel)
    }

    private func resetThumbstickVisual(_ itemID: Int) {
        guard let imageView = itemImageViews[itemID] else {
            return
        }

        UIView.animate(withDuration: 0.12) {
            imageView.alpha = 0.94
            imageView.transform = .identity
        }
    }

    private func notifyViewportChanged() {
        onGameViewportFrameChanged?(activeGameViewportFrame)
    }
}

private struct ActiveTouch {
    let item: ManicSkinResolvedItem
    var directionalInputs = Set<String>()
}

struct ManicSkinFallbackTarget {
    let itemID: Int
    let isThumbstick: Bool
    let description: String
}

private enum TouchTrackingKey: Hashable {
    case ui(ObjectIdentifier)
    case bridged(Int64)
}

final class TouchHapticFeedbackPerformer {
    static let shared = TouchHapticFeedbackPerformer()

    private var hapticEngine: CHHapticEngine?
    private var impactGenerator: UIImpactFeedbackGenerator?
    private var impactGeneratorLevel: TouchHapticFeedbackLevel = .off
    private let supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private init() {}

    func play() {
        play(level: .current)
    }

    func play(level: TouchHapticFeedbackLevel) {
        guard level != .off else {
            impactGenerator = nil
            impactGeneratorLevel = .off
            return
        }

        if supportsCoreHaptics {
            do {
                try playCoreHaptic(level: level)
                return
            } catch {
                NSLog("DukeX touch haptic Core Haptics fallback: %@", error.localizedDescription)
            }
        }

        playUIKitImpact(level: level)
    }

    private func playCoreHaptic(level: TouchHapticFeedbackLevel) throws {
        let engine = try coreHapticEngine()
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: level.hapticIntensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: level.hapticSharpness)
            ],
            relativeTime: 0
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: CHHapticTimeImmediate)
    }

    private func coreHapticEngine() throws -> CHHapticEngine {
        if let hapticEngine {
            return hapticEngine
        }

        let engine = try CHHapticEngine()
        engine.stoppedHandler = { [weak self] _ in
            self?.hapticEngine = nil
        }
        engine.resetHandler = { [weak self] in
            do {
                try self?.hapticEngine?.start()
            } catch {
                self?.hapticEngine = nil
            }
        }
        try engine.start()
        hapticEngine = engine
        return engine
    }

    private func playUIKitImpact(level: TouchHapticFeedbackLevel) {
        if impactGenerator == nil || impactGeneratorLevel != level {
            impactGenerator = UIImpactFeedbackGenerator(style: level.feedbackStyle)
            impactGeneratorLevel = level
            impactGenerator?.prepare()
        }

        impactGenerator?.impactOccurred()
        impactGenerator?.prepare()
    }
}

private extension TouchHapticFeedbackLevel {
    var feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .off, .low:
            return .light
        case .medium:
            return .medium
        case .high:
            return .heavy
        }
    }

    var hapticIntensity: Float {
        switch self {
        case .off:
            return 0
        case .low:
            return 0.35
        case .medium:
            return 0.7
        case .high:
            return 1
        }
    }

    var hapticSharpness: Float {
        switch self {
        case .off:
            return 0
        case .low:
            return 0.35
        case .medium:
            return 0.65
        case .high:
            return 0.95
        }
    }
}
