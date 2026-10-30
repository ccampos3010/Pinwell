import ARKit
import AVFoundation
import CoreImage
import CoreMotion
import CoreVideo
import Darwin
import QuartzCore
import UIKit

enum BoardLook: String, CaseIterable, Identifiable {
    case chrome
    case depth
    var id: String { rawValue }
}

struct PinFrame {
    var cols: Int
    var rows: Int
    var shown: [Float]
    var scale: Float
    var look: BoardLook
    var reflection: Float
    var blur: Float
    var env: UIImage?
}

struct TraceMail: Identifiable {
    let id = UUID()
    let report: String
    let file: URL
}

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
    @Published var look = BoardLook.chrome
    @Published var startCM = 25
    @Published var endCM = 15
    @Published var pinScale = 0.5
    @Published var reflection = 0.9
    @Published var blur = 0.18
    @Published var pinsLocked = false
    @Published var followsDepth = false
    @Published var depthImage: UIImage?
    @Published var traceMail: TraceMail?
    @Published var traceStatus: String?

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
    private var lastDepthImage = 0.0
    private let motion = CMMotionManager()
    private var config: ARFaceTrackingConfiguration?
    private var viewerDistance: Float = PinMath.defaultViewInches * 0.0254
    private var viewerRight: Float = 0
    private var viewerUp: Float = 0
    private var startM: Float = 0.25
    private var endM: Float = 0.15
    private var scale: Float = 0.5
    private var lookValue = BoardLook.chrome
    private var reflectionValue: Float = 0.9
    private var blurValue: Float = 0.18
    private var pinsHeld = false
    private var followDepth = false
    private let fusion = DepthFusion()
    private var frameDts: [Double] = []
    private var stepTimes: [Double] = []
    private var sceneTimes: [Double] = []
    private var depthTimes: [Double] = []
    private var touchCounts: [Int] = []
    private var shakeTimes: [Double] = []
    private var lastShake = 0.0
    private var captureRaw = Data()
    private var captureRawW = 0
    private var captureRawH = 0
    private var burstFrames: [BurstFrame] = []
    private var lastBurst = 0.0
    private var reflectionShot: UIImage?
    private var lastReflectionCapture = 0.0
    private var lastCaptureStore = 0.0
    private var captureJPEG: Data?
    private var captureDepth = Data()
    private var captureCW = 0
    private var captureCH = 0
    private var captureDW = 0
    private var captureDH = 0
    private let sessionQueue = DispatchQueue(label: "pinwell.session", qos: .userInteractive)
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    override init() {
        let n = 32 * PinMath.rows(for: 32)
        latched = Array(repeating: 0, count: n)
        smooth = Array(repeating: 0, count: n)
        shown = Array(repeating: 0, count: n)
        push = Array(repeating: 0, count: n)
        super.init()
        session.delegateQueue = sessionQueue
        session.delegate = self
    }

    func setViewport(_ size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }
        lock.lock()
        viewport = size
        lock.unlock()
    }

    func setStartCM(_ cm: Int) {
        let v = min(150, max(5, cm))
        lock.lock()
        startM = Float(v) / 100
        lock.unlock()
        startCM = v
    }

    func setEndCM(_ cm: Int) {
        let v = min(150, max(2, cm))
        lock.lock()
        endM = Float(v) / 100
        lock.unlock()
        endCM = v
    }

    func setPinScale(_ value: Double) {
        let v = min(2, max(0.1, value))
        lock.lock()
        scale = Float(v)
        lock.unlock()
        pinScale = v
    }

    func setShowsDepth(_ on: Bool) {
        setLook(on ? .depth : .chrome)
    }

    func setLook(_ next: BoardLook) {
        lock.lock()
        lookValue = next
        lock.unlock()
        look = next
    }

    func setReflection(_ value: Double) {
        let v = Float(min(1, max(0, value)))
        lock.lock()
        reflectionValue = v
        lock.unlock()
        reflection = Double(v)
    }

    func setBlur(_ value: Double) {
        let v = Float(min(1, max(0, value)))
        lock.lock()
        blurValue = v
        lock.unlock()
        blur = Double(v)
    }

    func setFollowsDepth(_ on: Bool) {
        lock.lock()
        followDepth = on
        lock.unlock()
        followsDepth = on
    }

    func togglePinsLock() {
        lock.lock()
        pinsHeld.toggle()
        let held = pinsHeld
        lock.unlock()
        pinsLocked = held
    }

    /// Writes one zip the computer-side preview can read: color.jpg, depth.f32, meta.json.
    func exportCapture(done: @escaping (URL?) -> Void) {
        lock.lock()
        let color = captureJPEG
        let depth = captureDepth
        let cw = captureCW
        let ch = captureCH
        let dw = captureDW
        let dh = captureDH
        let meta = """
        {"version":2,"colorWidth":\(cw),"colorHeight":\(ch),"depthWidth":\(dw),"depthHeight":\(dh),"rawWidth":\(captureRawW),"rawHeight":\(captureRawH),"depth":"float32-le-meters-row-major-sensor","depthRaw":"float32-le-meters-row-major-sensor","startM":\(startM),"endM":\(endM),"scale":\(scale),"cols":\(gridCols),"reflection":\(reflectionValue),"blur":\(blurValue),"followsDepth":\(followDepth),"look":"\(lookValue.rawValue)"}
        """
        let raw = captureRaw
        let rawW = captureRawW
        let rawH = captureRawH
        let report = traceReportLocked()
        let burst = burstFrames
        lock.unlock()
        guard let color, cw > 0, dw > 0, depth.count == dw * dh * 4 else {
            DispatchQueue.main.async { done(nil) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var files: [(String, Data)] = [
                ("color.jpg", color),
                ("depth.f32", depth),
                ("meta.json", Data(meta.utf8)),
                ("telemetry.txt", Data(report.utf8)),
            ]
            if rawW > 0 && raw.count == rawW * rawH * 4 {
                files.append(("depth-raw.f32", raw))
            }
            if let burst = Self.burstFiles(burst) {
                files.append(contentsOf: burst)
            }
            let zip = Self.zipStore(files)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PinwellCapture-\(Int(Date().timeIntervalSince1970)).zip")
            do {
                try zip.write(to: url, options: .atomic)
                DispatchQueue.main.async { done(url) }
            } catch {
                DispatchQueue.main.async { done(nil) }
            }
        }
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
    func step(dt: Double) -> PinFrame {
        let dtF = Float(min(0.05, max(0, dt)))
        lock.lock()
        let settling = skyFlat && !pinsHeld
        if !pinsHeld {
            if settling {
                retractPins(latched: &latched, smooth: &smooth, shown: &shown, dt: dtF)
            } else {
                stepPins(
                    latched: &latched,
                    smooth: &smooth,
                    shown: &shown,
                    push: push,
                    dt: dtF,
                    follow: followDepth
                )
            }
        }
        let frame = PinFrame(
            cols: gridCols,
            rows: gridRows,
            shown: shown,
            scale: scale,
            look: lookValue,
            reflection: reflectionValue,
            blur: blurValue,
            env: reflectionShot
        )
        lock.unlock()
        return frame
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        noteViewer(frame)
        lock.lock()
        let look = lookValue
        lock.unlock()
        if look == .chrome { captureReflection(frame) }
        guard let raw = frame.capturedDepthData else { return }
        let depthData = raw.depthDataType == kCVPixelFormatType_DepthFloat32
            ? raw
            : raw.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let started = CACurrentMediaTime()
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let fused = fusion.fuse(
            raw: base.assumingMemoryBound(to: Float.self),
            bytesPerRow: CVPixelBufferGetBytesPerRow(depthMap),
            width: width,
            height: height,
            pose: frame.camera.transform
        )
        fused.withUnsafeBufferPointer { ptr in
            guard let fusedBase = ptr.baseAddress else { return }
            let sample = DepthSample(
                width: width,
                height: height,
                floats: fusedBase,
                bytesPerRow: width * MemoryLayout<Float>.size,
                confidence: nil,
                confidenceStride: 0
            )
            let rawSample = DepthSample(
                width: width,
                height: height,
                floats: base.assumingMemoryBound(to: Float.self),
                bytesPerRow: CVPixelBufferGetBytesPerRow(depthMap),
                confidence: nil,
                confidenceStride: 0
            )
            copyDepth(frame: frame, sample: sample, raw: rawSample, drawDepth: look == .depth)
        }
        recordBurst(
            raw: base.assumingMemoryBound(to: Float.self),
            bytesPerRow: CVPixelBufferGetBytesPerRow(depthMap),
            width: width,
            height: height,
            pose: frame.camera.transform
        )
        noteDepth((CACurrentMediaTime() - started) * 1000)
    }

    private struct BurstFrame {
        var time: Double
        var width: Int
        var height: Int
        var pose: [Float]
        var depth: Data
    }

    private func recordBurst(
        raw: UnsafePointer<Float>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        pose: simd_float4x4
    ) {
        let now = CACurrentMediaTime()
        if now - lastBurst < (1.0 / 6.0) { return }
        lastBurst = now
        let count = width * height
        var halves = [Float16]()
        halves.reserveCapacity(count)
        for y in 0..<height {
            let row = UnsafeRawPointer(raw).advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                let z = row[x]
                halves.append(Float16(z.isFinite && z > 0 ? z : 0))
            }
        }
        let columns = pose.columns
        let packed: [Float] = [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w,
        ]
        let sample = BurstFrame(
            time: now,
            width: width,
            height: height,
            pose: packed,
            depth: halves.withUnsafeBytes { Data($0) }
        )
        lock.lock()
        burstFrames.append(sample)
        let cutoff = now - 5
        burstFrames.removeAll { $0.time < cutoff }
        lock.unlock()
    }

    private static func burstFiles(_ frames: [BurstFrame]) -> [(String, Data)]? {
        guard let first = frames.first, frames.count > 1 else { return nil }
        var depth = Data()
        var poses = "["
        for (index, frame) in frames.enumerated() {
            depth.append(frame.depth)
            if index > 0 { poses.append(",") }
            let numbers = frame.pose.map { String($0) }.joined(separator: ",")
            poses.append("{\"t\":\(frame.time),\"pose\":[\(numbers)]}")
        }
        poses.append("]")
        let count = frames.count
        let json = """
        {"format":"float16-le","width":\(first.width),"height":\(first.height),"fps":6,"seconds":5,"count":\(count),"pose":"column-major-simd-float4x4","frames":\(poses)}
        """
        return [("depth-burst.f16", depth), ("burst.json", Data(json.utf8))]
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
        sample: DepthSample,
        raw: DepthSample,
        drawDepth: Bool
    ) {
        lock.lock()
        let cols = gridCols
        let rows = gridRows
        let size = viewport
        let start = startM
        let end = endM
        lock.unlock()

        let display = frame.displayTransform(for: .portrait, viewportSize: size)
        let viewToImage = display.inverted()
        var next = [Float]()
        var near: Float = 0
        sampleDepthPins(
            depth: sample,
            viewToImage: viewToImage,
            cols: cols,
            rows: rows,
            start: start,
            end: end,
            push: &next,
            nearest: &near
        )
        lock.lock()
        if next.count == push.count {
            push = next
            nearest = near
        }
        lock.unlock()

        storeCapture(frame: frame, sample: sample, raw: raw)

        let now = CACurrentMediaTime()
        guard drawDepth, now - lastDepthImage > 0.12 else { return }
        lastDepthImage = now
        let portrait = sample.width >= sample.height
        let outW = portrait ? sample.height : sample.width
        let outH = portrait ? sample.width : sample.height
        let bytes = colorizeDepth(depth: sample, viewToImage: viewToImage, outWidth: outW, outHeight: outH, start: start, end: end)
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
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func storeCapture(frame: ARFrame, sample: DepthSample, raw: DepthSample) {
        let now = CACurrentMediaTime()
        if now - lastCaptureStore < 0.4 { return }
        lastCaptureStore = now

        let picture = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.rightMirrored)
        let bounds = picture.extent.integral
        guard bounds.width > 1, bounds.height > 1,
              let cg = ciContext.createCGImage(picture, from: bounds),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.92) else { return }

        let floats = Self.tightFloats(sample)
        let rawFloats = Self.tightFloats(raw)
        lock.lock()
        captureJPEG = jpeg
        captureDepth = floats.withUnsafeBytes { Data($0) }
        captureCW = cg.width
        captureCH = cg.height
        captureDW = sample.width
        captureDH = sample.height
        captureRaw = rawFloats.withUnsafeBytes { Data($0) }
        captureRawW = raw.width
        captureRawH = raw.height
        lock.unlock()
    }

    private static func tightFloats(_ sample: DepthSample) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, sample.width * sample.height))
        guard sample.width > 0, sample.height > 0 else { return out }
        for y in 0..<sample.height {
            let row = UnsafeRawPointer(sample.floats)
                .advanced(by: y * sample.bytesPerRow)
                .assumingMemoryBound(to: Float.self)
            for x in 0..<sample.width {
                let z = row[x]
                out[y * sample.width + x] = z.isFinite && z > 0 ? z : 0
            }
        }
        return out
    }

    private func captureReflection(_ frame: ARFrame) {
        let now = CACurrentMediaTime()
        if now - lastReflectionCapture < 1.0 / 12 { return }
        lastReflectionCapture = now
        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.rightMirrored)
        let bounds = image.extent.integral
        guard bounds.width > 1, bounds.height > 1, let cg = ciContext.createCGImage(image, from: bounds) else { return }
        let shot = UIImage(cgImage: cg)
        lock.lock()
        reflectionShot = shot
        lock.unlock()
    }

    private static func zipStore(_ files: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        var offset: UInt32 = 0
        for (name, data) in files {
            let nameData = Data(name.utf8)
            let crc = Self.crc32(data)
            let size = UInt32(data.count)
            var local = Data()
            local.append(le32(0x04034b50))
            local.append(le16(20))
            local.append(le16(0))
            local.append(le16(0))
            local.append(le16(0))
            local.append(le16(0))
            local.append(le32(crc))
            local.append(le32(size))
            local.append(le32(size))
            local.append(le16(UInt16(nameData.count)))
            local.append(le16(0))
            local.append(nameData)
            local.append(data)
            var entry = Data()
            entry.append(le32(0x02014b50))
            entry.append(le16(20))
            entry.append(le16(20))
            entry.append(le16(0))
            entry.append(le16(0))
            entry.append(le16(0))
            entry.append(le16(0))
            entry.append(le32(crc))
            entry.append(le32(size))
            entry.append(le32(size))
            entry.append(le16(UInt16(nameData.count)))
            entry.append(le16(0))
            entry.append(le16(0))
            entry.append(le16(0))
            entry.append(le16(0))
            entry.append(le32(0))
            entry.append(le32(offset))
            entry.append(nameData)
            out.append(local)
            central.append(entry)
            offset += UInt32(local.count)
        }
        let centralStart = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.append(le32(0x06054b50))
        end.append(le16(0))
        end.append(le16(0))
        end.append(le16(UInt16(files.count)))
        end.append(le16(UInt16(files.count)))
        end.append(le32(UInt32(central.count)))
        end.append(le32(centralStart))
        end.append(le16(0))
        out.append(end)
        return out
    }

    private static func le16(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 2)
    }

    private static func le32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xEDB8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return ~crc
    }

    func noteFrame(dt: Double, stepMs: Double, sceneMs: Double, updated: Int) {
        lock.lock()
        if frameDts.count >= 180 { frameDts.removeFirst() }
        frameDts.append(dt)
        if stepTimes.count >= 180 { stepTimes.removeFirst() }
        stepTimes.append(stepMs)
        if sceneTimes.count >= 180 { sceneTimes.removeFirst() }
        sceneTimes.append(sceneMs)
        if touchCounts.count >= 180 { touchCounts.removeFirst() }
        touchCounts.append(updated)
        lock.unlock()
    }

    func sendTrace() {
        exportCapture { [weak self] url in
            guard let self else { return }
            guard let url else {
                self.traceStatus = "No frame yet. Hold still a moment, then shake again."
                return
            }
            self.traceMail = TraceMail(report: self.latestReport(), file: url)
            self.traceStatus = "Opening the trace email."
        }
    }

    private func latestReport() -> String {
        lock.lock()
        let report = traceReportLocked()
        lock.unlock()
        return report
    }

    private func noteDepth(_ ms: Double) {
        lock.lock()
        if depthTimes.count >= 180 { depthTimes.removeFirst() }
        depthTimes.append(ms)
        lock.unlock()
    }

    private func traceReportLocked() -> String {
        let fusionStat = fusion.snapshot()
        let fps = frameDts.filter { $0 > 0.0001 }.map { 1 / $0 }
        let agree = fusionStat.tested > 0 ? Double(fusionStat.agreed) / Double(fusionStat.tested) : 0
        return """
        Pinwell telemetry
        device \(Self.machineName()) \(UIDevice.current.systemVersion)
        look \(lookValue.rawValue) follow \(followDepth) locked \(pinsHeld)
        cols \(gridCols) start \(startM) end \(endM) scale \(scale)
        reflect \(reflectionValue) blur \(blurValue)
        frames \(frameDts.count)
        fps p50 \(pct(fps, 0.5)) p10 \(pct(fps, 0.1))
        frame ms p50 \(pct(frameDts.map { $0 * 1000 }, 0.5)) p90 \(pct(frameDts.map { $0 * 1000 }, 0.9))
        step ms p50 \(pct(stepTimes, 0.5)) p90 \(pct(stepTimes, 0.9))
        scene ms p50 \(pct(sceneTimes, 0.5)) p90 \(pct(sceneTimes, 0.9))
        depth ms p50 \(pct(depthTimes, 0.5)) p90 \(pct(depthTimes, 0.9))
        nodes updated p50 \(pct(touchCounts.map(Double.init), 0.5))
        fusion agree \(String(format: "%.3f", agree)) resets \(fusionStat.resets) stable \(fusionStat.stable) moving \(fusionStat.moving)
        color \(captureCW)x\(captureCH) depthView \(captureDW)x\(captureDH) depthRaw \(captureRawW)x\(captureRawH)
        """
    }

    private func pct(_ values: [Double], _ p: Double) -> String {
        guard !values.isEmpty else { return "-" }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return String(format: "%.2f", sorted[index])
    }

    private static func machineName() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
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
            let accel = data.userAcceleration
            let mag = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)
            if mag > 2.4 {
                let now = CACurrentMediaTime()
                self.lock.lock()
                self.shakeTimes.append(now)
                self.shakeTimes.removeAll { now - $0 > 0.7 }
                let ready = self.shakeTimes.count >= 2 && now - self.lastShake > 8
                if ready {
                    self.lastShake = now
                    self.shakeTimes.removeAll()
                }
                self.lock.unlock()
                if ready {
                    DispatchQueue.main.async { self.sendTrace() }
                }
            }
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
        "TrueDepth is live. Hold something within the start distance of the screen. Lay the screen flat, toward the sky, to slide the pins back. Shake to email a performance trace."
    }

    private var missingHint: String {
        "This iPhone has no TrueDepth camera. Pinwell needs a Face ID iPhone."
    }
}
