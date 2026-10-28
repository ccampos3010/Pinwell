import ARKit
import CoreMotion
import QuartzCore
import UIKit

enum LidarState: Equatable {
    case checking
    case live
    case missing
    case denied
}

final class BoardModel: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published var cols = 32
    @Published var rows = PinMath.rows(for: 32)
    @Published var nearestCM: Int?
    @Published var posture = "Starting"
    @Published var hint = "Starting the LiDAR camera."
    @Published var lidar: LidarState = .checking
    @Published var sliding = false

    private let lock = NSLock()
    private var gridCols = 32
    private var gridRows = PinMath.rows(for: 32)
    private var latched: [Float]
    private var smooth: [Float]
    private var shown: [Float]
    private var push: [Float]
    private var nearest: Float = 0
    private var skyFlat = false
    private var skyArmed = false
    private var viewport = CGSize(width: 390, height: 844)
    private var lastUI = 0.0
    private let motion = CMMotionManager()
    private var config: ARWorldTrackingConfiguration?
    private var viewerDistance: Float = PinMath.defaultViewInches * 0.0254
    private var viewerRight: Float = 0
    private var viewerUp: Float = 0
    private var faceTracking = false
    private var droppedFace = false

    override init() {
        let n = 32 * PinMath.rows(for: 32)
        latched = Array(repeating: 0, count: n)
        smooth = Array(repeating: 0, count: n)
        shown = Array(repeating: 0, count: n)
        push = Array(repeating: 0, count: n)
        super.init()
        session.delegate = self
    }

    func setViewport(_ size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }
        lock.lock()
        viewport = size
        lock.unlock()
    }

    func setCols(_ next: Int) {
        let cols = PinMath.clampCols(next)
        let rows = PinMath.rows(for: cols)
        lock.lock()
        if cols == gridCols {
            lock.unlock()
            return
        }
        let n = cols * rows
        latched = Array(repeating: 0, count: n)
        smooth = Array(repeating: 0, count: n)
        shown = Array(repeating: 0, count: n)
        push = Array(repeating: 0, count: n)
        nearest = 0
        gridCols = cols
        gridRows = rows
        lock.unlock()
        self.cols = cols
        self.rows = rows
        self.nearestCM = nil
    }

    func resetPins() {
        lock.lock()
        latched = Array(repeating: 0, count: latched.count)
        smooth = Array(repeating: 0, count: smooth.count)
        shown = Array(repeating: 0, count: shown.count)
        skyFlat = false
        skyArmed = false
        lock.unlock()
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            publish(lidar: .missing, posture: "No LiDAR", hint: missingHint, sliding: false)
            return
        }
        let semantics: ARConfiguration.FrameSemantics
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            semantics = .smoothedSceneDepth
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            semantics = .sceneDepth
        } else {
            publish(lidar: .missing, posture: "No LiDAR", hint: missingHint, sliding: false)
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = semantics
        config.planeDetection = []
        config.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsUserFaceTracking {
            config.userFaceTrackingEnabled = true
            faceTracking = true
        }
        self.config = config
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        publish(lidar: .live, posture: "Sensor", hint: liveHint, sliding: false)
        startMotion()
    }

    func stop() {
        session.pause()
        motion.stopDeviceMotionUpdates()
    }

    /// Eye position above the board. Falls back to 12 inches, straight on, until a face is tracked.
    func viewerEye() -> SIMD3<Float> {
        lock.lock()
        let d = viewerDistance
        let r = viewerRight
        let u = viewerUp
        lock.unlock()
        return PinMath.eye(distanceM: d, rightM: r, upM: u)
    }
    func step(dt: Double) -> (cols: Int, rows: Int, shown: [Float]) {
        let dtF = Float(min(0.05, max(0, dt)))
        lock.lock()
        let settling = skyFlat
        if settling {
            retractPins(latched: &latched, smooth: &smooth, shown: &shown, dt: dtF)
        } else {
            stepPins(latched: &latched, smooth: &smooth, shown: &shown, push: push, dt: dtF)
        }
        let snapshot = shown
        let cols = gridCols
        let rows = gridRows
        let near = nearest
        let armed = skyArmed
        lock.unlock()

        let now = CACurrentMediaTime()
        if now - lastUI > 0.14 {
            lastUI = now
            let cm: Int? = near > 0 ? Int((near * 100).rounded()) : nil
            let posture = settling ? "Sliding" : (near > 0 && near < PinMath.contactM ? "Pressing" : "Sensor")
            let hint = settling
                ? (armed
                    ? "Sliding back. Tilt up to pause — about 3 seconds from fully out to flush."
                    : "Sliding back. About 3 seconds from fully out to flush.")
                : liveHint
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lidar == .live else { return }
                self.nearestCM = cm
                self.posture = posture
                self.hint = hint
                self.sliding = settling
            }
        }
        return (cols, rows, snapshot)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        noteViewer(frame)
        let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        guard let depthMap else { return }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }

        var confidence: UnsafePointer<UInt8>?
        var confidenceStride = 0
        let confMap = frame.smoothedSceneDepth?.confidenceMap ?? frame.sceneDepth?.confidenceMap
        if let confMap {
            CVPixelBufferLockBaseAddress(confMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confMap, .readOnly) }
            if let confBase = CVPixelBufferGetBaseAddress(confMap) {
                confidence = confBase.assumingMemoryBound(to: UInt8.self)
                confidenceStride = CVPixelBufferGetBytesPerRow(confMap)
                copyDepth(frame: frame, depthMap: depthMap, base: base, confidence: confidence, confidenceStride: confidenceStride)
            }
            return
        }
        copyDepth(frame: frame, depthMap: depthMap, base: base, confidence: nil, confidenceStride: 0)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let code = (error as NSError).code
        if code == ARError.Code.cameraUnauthorized.rawValue {
            publish(
                lidar: .denied,
                posture: "Blocked",
                hint: "Camera access is off. Turn it on in Settings for Pinwell.",
                sliding: false
            )
            return
        }
        if faceTracking, !droppedFace, let config {
            droppedFace = true
            faceTracking = false
            config.userFaceTrackingEnabled = false
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {}

    func sessionInterruptionEnded(_ session: ARSession) {
        if let config { session.run(config, options: []) }
    }

    private func noteViewer(_ frame: ARFrame) {
        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        let faceInView = simd_mul(frame.camera.viewMatrix(for: .portrait), face.transform)
        let p = faceInView.columns.3
        let distance = min(0.9, max(0.18, abs(p.z)))
        let right = min(0.12, max(-0.12, p.x))
        let up = min(0.12, max(-0.12, p.y))
        lock.lock()
        viewerDistance += (distance - viewerDistance) * 0.2
        viewerRight += (right - viewerRight) * 0.2
        viewerUp += (up - viewerUp) * 0.2
        lock.unlock()
    }

    private func copyDepth(
        frame: ARFrame,
        depthMap: CVPixelBuffer,
        base: UnsafeMutableRawPointer,
        confidence: UnsafePointer<UInt8>?,
        confidenceStride: Int
    ) {
        lock.lock()
        let cols = gridCols
        let rows = gridRows
        let size = viewport
        lock.unlock()

        let display = frame.displayTransform(for: .portrait, viewportSize: size)
        let viewToImage = display.inverted()
        let sample = DepthSample(
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap),
            floats: base.assumingMemoryBound(to: Float.self),
            bytesPerRow: CVPixelBufferGetBytesPerRow(depthMap),
            confidence: confidence,
            confidenceStride: confidenceStride
        )
        var next = [Float]()
        var near: Float = 0
        sampleDepthPins(depth: sample, viewToImage: viewToImage, cols: cols, rows: rows, push: &next, nearest: &near)
        lock.lock()
        if next.count == push.count {
            push = next
            nearest = near
        }
        lock.unlock()
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] data, _ in
            guard let self, let data else { return }
            let tilt = PinMath.tiltFromFaceUp(data.gravity)
            self.lock.lock()
            if tilt > PinMath.releaseDeg { self.skyArmed = true }
            if self.skyArmed {
                self.skyFlat = PinMath.skyHold(wasHolding: self.skyFlat, tiltDeg: tilt)
            } else {
                self.skyFlat = false
            }
            self.lock.unlock()
        }
    }

    private func publish(lidar: LidarState, posture: String, hint: String, sliding: Bool) {
        DispatchQueue.main.async {
            self.lidar = lidar
            self.posture = posture
            self.hint = hint
            self.sliding = sliding
        }
    }

    private var liveHint: String {
        "LiDAR is live. Hold something within 25 cm of the back of the phone. Lay the screen flat, toward the sky, to slide the pins back."
    }

    private var missingHint: String {
        "This iPhone has no LiDAR sensor. Pinwell needs an iPhone 12 Pro or any newer Pro."
    }
}
