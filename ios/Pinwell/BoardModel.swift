import ARKit
import AVFoundation
import CoreMotion
import CoreVideo
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
    @Published var hint = "Starting the front depth camera."
    @Published var lidar: LidarState = .checking
    @Published var sliding = false
    @Published var showsDepth = false
    @Published var startCM = 25
    @Published var spanCM = 10
    @Published var pinScale = 0.5
    @Published var depthImage: UIImage?

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
    private var lastDepthImage = 0.0
    private let motion = CMMotionManager()
    private var config: ARFaceTrackingConfiguration?
    private var viewerDistance: Float = PinMath.defaultViewInches * 0.0254
    private var viewerRight: Float = 0
    private var viewerUp: Float = 0
    private var startM: Float = 0.25
    private var spanM: Float = 0.10
    private var scale: Float = 0.5
    private var wantDepth = false

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

    func setStartCM(_ cm: Int) {
        let v = min(100, max(10, cm))
        lock.lock()
        startM = Float(v) / 100
        lock.unlock()
        startCM = v
    }

    func setSpanCM(_ cm: Int) {
        let v = min(40, max(2, cm))
        lock.lock()
        spanM = Float(v) / 100
        lock.unlock()
        spanCM = v
    }

    func setPinScale(_ value: Double) {
        let v = min(2, max(0.1, value))
        lock.lock()
        scale = Float(v)
        lock.unlock()
        pinScale = v
    }

    func setShowsDepth(_ on: Bool) {
        lock.lock()
        wantDepth = on
        lock.unlock()
        showsDepth = on
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
        guard ARFaceTrackingConfiguration.isSupported else {
            publish(lidar: .missing, posture: "No TrueDepth", hint: missingHint, sliding: false)
            return
        }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = false
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
    func step(dt: Double) -> (cols: Int, rows: Int, shown: [Float], scale: Float) {
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
        let pinScale = self.scale
        let start = startM
        lock.unlock()

        let now = CACurrentMediaTime()
        if now - lastUI > 0.14 {
            lastUI = now
            let cm: Int? = near > 0 ? Int((near * 100).rounded()) : nil
            let posture = settling ? "Sliding" : (near > 0 && near < start ? "Pressing" : "Sensor")
            let hint = settling
                ? (armed
                    ? "Sliding back. Tilt up to pause - about 3 seconds from fully out to flush."
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
        return (cols, rows, snapshot, pinScale)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        noteViewer(frame)
        guard let raw = frame.capturedDepthData else { return }
        let depthData = raw.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }
        copyDepth(frame: frame, depthMap: depthMap, base: base)
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
        base: UnsafeMutableRawPointer
    ) {
        lock.lock()
        let cols = gridCols
        let rows = gridRows
        let size = viewport
        let start = startM
        let span = spanM
        let draw = wantDepth
        lock.unlock()

        let display = frame.displayTransform(for: .portrait, viewportSize: size)
        let viewToImage = display.inverted()
        let sample = DepthSample(
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap),
            floats: base.assumingMemoryBound(to: Float.self),
            bytesPerRow: CVPixelBufferGetBytesPerRow(depthMap),
            confidence: nil,
            confidenceStride: 0
        )
        var next = [Float]()
        var near: Float = 0
        sampleDepthPins(
            depth: sample,
            viewToImage: viewToImage,
            cols: cols,
            rows: rows,
            start: start,
            span: span,
            push: &next,
            nearest: &near
        )
        lock.lock()
        if next.count == push.count {
            push = next
            nearest = near
        }
        lock.unlock()

        let now = CACurrentMediaTime()
        guard draw, now - lastDepthImage > 0.1 else { return }
        lastDepthImage = now
        let outW = 200
        let outH = max(200, Int((Double(outW) * Double(size.height) / Double(max(size.width, 1))).rounded()))
        let bytes = colorizeDepth(depth: sample, viewToImage: viewToImage, outWidth: outW, outHeight: outH, start: start)
        guard let image = image(from: bytes, width: outW, height: outH) else { return }
        if Thread.isMainThread {
            depthImage = image
        } else {
            DispatchQueue.main.async { [weak self] in self?.depthImage = image }
        }
    }

    private func image(from bytes: [UInt8], width: Int, height: Int) -> UIImage? {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cg)
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
        "TrueDepth is live. Hold something within the start distance of the screen. Lay the screen flat, toward the sky, to slide the pins back."
    }

    private var missingHint: String {
        "This iPhone has no TrueDepth camera. Pinwell needs a Face ID iPhone."
    }
}
