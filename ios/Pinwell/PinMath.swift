import CoreMotion
import CoreGraphics

enum PinMath {
    static let contactM: Float = 0.25
    static let nearM: Float = 0.05
    static let travel: Float = 0.62
    static let minHeight: Float = 0.004
    static let fullResetSec: Float = 3
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

    static func pushAmount(_ z: Float) -> Float {
        if !(z >= nearM) || z >= contactM { return 0 }
        return (contactM - z) / (contactM - nearM)
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

    static func height(_ shown: Float) -> Float {
        let t = min(1, max(0, shown))
        return minHeight + t * travel
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
    push: inout [Float],
    nearest: inout Float
) {
    let count = cols * rows
    if push.count != count { push = Array(repeating: 0, count: count) }
    var best: Float = 0
    let window = max(1, depth.width / max(cols, 1) / 2)
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
                        if z.isFinite && z >= PinMath.nearM && z < 8 && (close == 0 || z < close) {
                            close = z
                        }
                    }
                }
            }
            if close > 0 && (best == 0 || close < best) { best = close }
            push[row * cols + col] = PinMath.pushAmount(close)
        }
    }
    nearest = best
}

func stepPins(
    latched: inout [Float],
    smooth: inout [Float],
    shown: inout [Float],
    push: [Float],
    dt: Float
) {
    let cap = min(Float(0.05), dt)
    let kSmooth = 1 - exp(-12 * cap)
    let kRise = 1 - exp(-5.5 * cap)
    let kFall = 1 - exp(-8 * cap)
    for i in 0..<latched.count {
        let p = i < push.count ? push[i] : 0
        let s0 = smooth[i]
        let s = s0 + (p - s0) * kSmooth
        smooth[i] = s
        var lat = latched[i]
        if s > lat { lat = s }
        latched[i] = lat
        let vis = shown[i]
        let k: Float = lat >= vis ? kRise : kFall
        shown[i] = vis + (lat - vis) * k
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
