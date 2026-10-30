import CoreMotion
import CoreGraphics

enum PinMath {
    static let contactM: Float = 0.25
    static let nearM: Float = 0.05
    static let travel: Float = 0.62
    static let minHeight: Float = 0.004
    static let fullResetSec: Float = 1.5
    static let engageDeg = 8.0
    static let releaseDeg = 10.0
    static let boardW: Float = 1.02
    static let boardH: Float = 2.16
    /// iPhone 16 Pro glass, used so a 12-inch viewing distance matches the screen.
    static let screenWInches: Float = 2.622
    static let screenHInches: Float = 5.700
    static let defaultViewInches: Float = 12

    static var defaultEyeDistance: Float { boardH * defaultViewInches / screenHInches }

    /// Eye position in board units. The board fills the glass. Y is above the pins.
    static func eye(distanceM: Float, rightM: Float, upM: Float) -> SIMD3<Float> {
        let d = min(0.9, max(0.18, distanceM))
        let y = d / (screenHInches * 0.0254) * boardH
        let x = rightM / (screenWInches * 0.0254) * boardW
        let z = -upM / (screenHInches * 0.0254) * boardH
        return SIMD3(x, y, z)
    }

    static func rows(for cols: Int) -> Int {
        max(10, Int((Double(cols) * Double(boardH / boardW)).rounded()))
    }

    static func clampCols(_ n: Int) -> Int {
        min(48, max(16, n))
    }

    /// Farther absolute distance is where the balls start. Nearer is full travel.
    static func rangeEdges(start: Float, end: Float) -> (far: Float, near: Float) {
        let a = max(0.02, start)
        let b = max(0.02, end)
        let far = max(a, b)
        let near = min(a, b)
        if far - near < 0.005 { return (far, max(0.02, far - 0.005)) }
        return (far, near)
    }

    static func pushAmount(_ z: Float, start: Float, end: Float) -> Float {
        if !z.isFinite || z <= 0 { return 0 }
        let edges = rangeEdges(start: start, end: end)
        if z >= edges.far { return 0 }
        if z <= edges.near { return 1 }
        return (edges.far - z) / (edges.far - edges.near)
    }

    /// Degrees away from screen-up and level. 0 is flat, face to the sky.
    static func tiltFromFaceUp(_ g: CMAcceleration) -> Double {
        let horiz = (g.x * g.x + g.y * g.y).squareRoot()
        let faceUp = max(-1, min(1, -g.z))
        return atan2(horiz, faceUp) * 180 / .pi
    }

    static func skyHold(wasHolding: Bool, tiltDeg: Double) -> Bool {
        if wasHolding { return tiltDeg <= releaseDeg }
        return tiltDeg <= engageDeg
    }

    static let colorFarM: Float = 1.2

    static func height(_ shown: Float, scale: Float) -> Float {
        let t = min(1, max(0, shown))
        let s = min(2, max(0.1, scale))
        return minHeight + t * travel * s
    }
}

struct DepthSample {
    let width: Int
    let height: Int
    let floats: UnsafePointer<Float>
    let bytesPerRow: Int
    let confidence: UnsafePointer<UInt8>?
    let confidenceStride: Int
}

func sampleDepthPins(
    depth: DepthSample,
    viewToImage: CGAffineTransform,
    cols: Int,
    rows: Int,
    start: Float,
    end: Float,
    push: inout [Float],
    nearest: inout Float
) {
    let count = cols * rows
    if push.count != count { push = Array(repeating: 0, count: count) }
    var best: Float = 0
    let window = 0
    for row in 0..<rows {
        for col in 0..<cols {
            let u = (CGFloat(col) + 0.5) / CGFloat(cols)
            let v = (CGFloat(row) + 0.5) / CGFloat(rows)
            let p = CGPoint(x: u, y: v).applying(viewToImage)
            let px = Int((p.x * CGFloat(depth.width)).rounded())
            let py = Int((p.y * CGFloat(depth.height)).rounded())
            var close: Float = 0
            if px >= 0 && py >= 0 && px < depth.width && py < depth.height {
                for dy in -window...window {
                    let y = py + dy
                    if y < 0 || y >= depth.height { continue }
                    let rowF = UnsafeRawPointer(depth.floats)
                        .advanced(by: y * depth.bytesPerRow)
                        .assumingMemoryBound(to: Float.self)
                    let rowC = depth.confidence.map {
                        UnsafeRawPointer($0).advanced(by: y * depth.confidenceStride).assumingMemoryBound(to: UInt8.self)
                    }
                    for dx in -window...window {
                        let x = px + dx
                        if x < 0 || x >= depth.width { continue }
                        if let rowC, rowC[x] == 0 { continue }
                        let z = rowF[x]
                        if z.isFinite && z > 0 && z < 8 && (close == 0 || z < close) {
                            close = z
                        }
                    }
                }
            }
            if close > 0 && (best == 0 || close < best) { best = close }
            push[row * cols + col] = PinMath.pushAmount(close, start: start, end: end)
        }
    }
    nearest = best
}

func stepPins(
    latched: inout [Float],
    smooth: inout [Float],
    shown: inout [Float],
    push: [Float],
    dt: Float,
    follow: Bool
) {
    let cap = min(Float(0.05), dt)
    let kSmooth = 1 - exp(-12 * cap)
    let kRise = 1 - exp(-5.5 * cap)
    let kFall = 1 - exp(-16 * cap)
    let kBack = 1 - exp(-2.75 * cap)
    for i in 0..<latched.count {
        let p = i < push.count ? push[i] : 0
        let s0 = smooth[i]
        let s = s0 + (p - s0) * kSmooth
        smooth[i] = s
        if follow {
            let vis = shown[i]
            let k: Float = s >= vis ? kRise : kBack
            let next = vis + (s - vis) * k
            shown[i] = next
            latched[i] = next
        } else {
            var lat = latched[i]
            if s > lat { lat = s }
            latched[i] = lat
            let vis = shown[i]
            let k: Float = lat >= vis ? kRise : kFall
            shown[i] = vis + (lat - vis) * k
        }
    }
}

func retractPins(latched: inout [Float], smooth: inout [Float], shown: inout [Float], dt: Float) {
    let drop = dt / PinMath.fullResetSec
    for i in 0..<shown.count {
        let h = max(0, shown[i] - drop)
        shown[i] = h
        latched[i] = h
        smooth[i] = h
    }
}

func depthPixel(z: Float, start: Float, end: Float) -> (UInt8, UInt8, UInt8) {
    if !z.isFinite || z <= 0 { return (0, 0, 0) }
    let edges = PinMath.rangeEdges(start: start, end: end)
    if z > edges.far {
        let limit = max(edges.far + 0.25, PinMath.colorFarM)
        let t = min(1, (z - edges.far) / (limit - edges.far))
        let blue = UInt8(40 + (1 - t) * 215)
        let spill = UInt8((1 - t) * 50)
        return (spill, spill, blue)
    }
    if z < edges.near {
        let t = min(1, (edges.near - z) / max(edges.near, 0.05))
        let red = UInt8(170 + t * 85)
        let other = UInt8((1 - t) * 36)
        return (red, other, other)
    }
    let t = (edges.far - z) / (edges.far - edges.near)
    let gray = UInt8(48 + t * 176)
    return (gray, gray, gray)
}

func colorizeDepth(
    depth: DepthSample,
    viewToImage: CGAffineTransform,
    outWidth: Int,
    outHeight: Int,
    start: Float,
    end: Float
) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
    for y in 0..<outHeight {
        for x in 0..<outWidth {
            let u = (CGFloat(x) + 0.5) / CGFloat(outWidth)
            let v = (CGFloat(y) + 0.5) / CGFloat(outHeight)
            let p = CGPoint(x: u, y: v).applying(viewToImage)
            let px = Int((p.x * CGFloat(depth.width)).rounded())
            let py = Int((p.y * CGFloat(depth.height)).rounded())
            var z: Float = 0
            if px >= 0, py >= 0, px < depth.width, py < depth.height {
                let row = UnsafeRawPointer(depth.floats)
                    .advanced(by: py * depth.bytesPerRow)
                    .assumingMemoryBound(to: Float.self)
                z = row[px]
            }
            let c = depthPixel(z: z, start: start, end: end)
            let i = (y * outWidth + x) * 4
            bytes[i] = c.0
            bytes[i + 1] = c.1
            bytes[i + 2] = c.2
            bytes[i + 3] = 255
        }
    }
    return bytes
}
