import QuartzCore
import SceneKit
import simd
import SwiftUI

struct PinSceneView: UIViewRepresentable {
    @ObservedObject var model: BoardModel

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = UIColor(red: 0.05, green: 0.045, blue: 0.04, alpha: 1)
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.delegate = context.coordinator
        view.autoenablesDefaultLighting = false
        view.isUserInteractionEnabled = false
        context.coordinator.owner = model
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.owner = model
        context.coordinator.frameCamera(viewSize: uiView.bounds.size)
        model.setViewport(uiView.bounds.size)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let scene = SCNScene()
        let camera = SCNNode()
        let board = SCNNode()
        private var shafts: [SCNNode] = []
        private var caps: [SCNNode] = []
        private var cols = 0
        private var rows = 0
        private var last = 0.0
        private var lastShown: [Float] = []
        private var appliedLook = BoardLook.chrome
        private var lastReflection: Float = -1
        private var lastBlur: Float = -1
        private var lastScale: Float = -1
        private var lastEnv: UIImage?
        var owner: BoardModel?
        private let shaftGeo: SCNCylinder
        private let capGeo: SCNSphere
        private let shaftMat = SCNMaterial()
        private let capMat = SCNMaterial()
        private let chromeMat = SCNMaterial()

        override init() {
            shaftGeo = SCNCylinder(radius: 1, height: 1)
            shaftGeo.radialSegmentCount = 8
            capGeo = SCNSphere(radius: 1)
            capGeo.segmentCount = 12
            super.init()
            metal(shaftMat, rough: 0.38, shade: 0.62)
            metal(capMat, rough: 0.16, shade: 0.86)
            chromeMat.lightingModel = .physicallyBased
            chromeMat.diffuse.contents = UIColor(white: 0.02, alpha: 1)
            chromeMat.metalness.contents = 1.0
            chromeMat.roughness.contents = 0.12
            chromeMat.reflective.contents = UIColor(white: 0.7, alpha: 1)
            chromeMat.reflective.intensity = 1.4
            shaftGeo.materials = [shaftMat]
            capGeo.materials = [chromeMat]
            buildStudio()
        }

        func frameCamera(viewSize: CGSize) {
            guard viewSize.width > 2, viewSize.height > 2 else { return }
            let eye = owner?.viewerEye() ?? PinMath.eye(
                distanceM: PinMath.defaultViewInches * 0.0254,
                rightM: 0,
                upM: 0
            )
            camera.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            camera.position = SCNVector3(eye.x, eye.y, eye.z)
            let near: Float = 0.05
            let far: Float = 40
            let d = max(eye.y, near * 4)
            let left = (-PinMath.boardW / 2 - eye.x) * near / d
            let right = (PinMath.boardW / 2 - eye.x) * near / d
            let bottom = (-PinMath.boardH / 2 + eye.z) * near / d
            let top = (PinMath.boardH / 2 + eye.z) * near / d
            camera.camera?.usesOrthographicProjection = false
            camera.camera?.projectionTransform = SCNMatrix4(Self.frustum(
                left: left, right: right, bottom: bottom, top: top, near: near, far: far
            ))
        }

        /// Straight down. An off-center eye shifts the pins, not the board on the glass.
        private static func frustum(
            left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float
        ) -> simd_float4x4 {
            let rl = right - left
            let tb = top - bottom
            let fn = far - near
            return simd_float4x4(columns: (
                SIMD4(2 * near / rl, 0, 0, 0),
                SIMD4(0, 2 * near / tb, 0, 0),
                SIMD4((right + left) / rl, (top + bottom) / tb, -(far + near) / fn, -1),
                SIMD4(0, 0, -2 * far * near / fn, 0)
            ))
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let model = owner else { return }
            let dt = last == 0 ? 0 : time - last
            last = time
            let stepStart = CACurrentMediaTime()
            let frame = model.step(dt: dt)
            let stepMs = (CACurrentMediaTime() - stepStart) * 1000
            if frame.cols != cols || frame.rows != rows {
                rebuild(cols: frame.cols, rows: frame.rows)
                lastShown.removeAll(keepingCapacity: true)
            }
            let n = min(frame.shown.count, shafts.count)
            guard frame.cols > 0, frame.rows > 0, n > 0 else { return }
            if frame.look != appliedLook {
                appliedLook = frame.look
                lastShown.removeAll(keepingCapacity: true)
            }
            if abs(frame.reflection - lastReflection) > 0.005 || abs(frame.blur - lastBlur) > 0.005 {
                lastReflection = frame.reflection
                lastBlur = frame.blur
                chromeMat.metalness.contents = 1.0
                chromeMat.roughness.contents = max(0.05, frame.blur * 0.45)
                chromeMat.reflective.intensity = CGFloat(0.35 + frame.reflection * 1.3)
                scene.lightingEnvironment.intensity = CGFloat(0.6 + frame.reflection)
            }
            if let env = frame.env, env !== lastEnv {
                chromeMat.reflective.contents = env
                scene.lightingEnvironment.contents = env
                lastEnv = env
                lastShown.removeAll(keepingCapacity: true)
            }
            if abs(frame.scale - lastScale) > 0.001 {
                lastScale = frame.scale
                lastShown.removeAll(keepingCapacity: true)
            }
            if lastShown.count != n { lastShown = Array(repeating: -1, count: n) }
            let pitch = min(PinMath.boardW / Float(frame.cols), PinMath.boardH / Float(frame.rows))
            let ball = pitch * 0.46
            let sceneStart = CACurrentMediaTime()
            var updated = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for i in 0..<n {
                let shown = frame.shown[i]
                if abs(shown - lastShown[i]) < 0.004 { continue }
                updated += 1
                lastShown[i] = shown
                let h = PinMath.height(shown, scale: frame.scale)
                let x = ((Float(i % frame.cols) + 0.5) / Float(frame.cols)) * PinMath.boardW - PinMath.boardW / 2
                let z = PinMath.boardH / 2 - ((Float(i / frame.cols) + 0.5) / Float(frame.rows)) * PinMath.boardH
                shafts[i].isHidden = true
                caps[i].simdPosition = SIMD3(x, h, z)
                caps[i].simdScale = SIMD3(ball, ball, ball)
            }
            CATransaction.commit()
            model.noteFrame(
                dt: dt,
                stepMs: stepMs,
                sceneMs: (CACurrentMediaTime() - sceneStart) * 1000,
                updated: updated
            )
        }

        private func metal(_ mat: SCNMaterial, rough: CGFloat, shade: CGFloat) {
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = UIColor(white: shade, alpha: 1)
            mat.metalness.contents = 0.86
            mat.roughness.contents = rough
        }

        private func buildStudio() {
            scene.rootNode.addChildNode(board)

            let plate = SCNNode(geometry: SCNPlane(width: CGFloat(PinMath.boardW), height: CGFloat(PinMath.boardH)))
            plate.eulerAngles.x = -.pi / 2
            plate.geometry?.firstMaterial?.lightingModel = .physicallyBased
            plate.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.045, green: 0.04, blue: 0.036, alpha: 1)
            plate.geometry?.firstMaterial?.roughness.contents = 0.92
            plate.geometry?.firstMaterial?.metalness.contents = 0.02
            board.addChildNode(plate)

            let frame = SCNMaterial()
            frame.lightingModel = .physicallyBased
            frame.diffuse.contents = UIColor(red: 0.09, green: 0.08, blue: 0.07, alpha: 1)
            frame.roughness.contents = 0.55
            frame.metalness.contents = 0.28
            let t: CGFloat = 0.045
            let hw = CGFloat(PinMath.boardW) / 2
            let hh = CGFloat(PinMath.boardH) / 2
            let bars: [(CGFloat, CGFloat, CGFloat, Float, Float)] = [
                (CGFloat(PinMath.boardW) + t * 2, t, 0.05, 0, Float(hh + t / 2)),
                (CGFloat(PinMath.boardW) + t * 2, t, 0.05, 0, -Float(hh + t / 2)),
                (t, CGFloat(PinMath.boardH), 0.05, -Float(hw + t / 2), 0),
                (t, CGFloat(PinMath.boardH), 0.05, Float(hw + t / 2), 0),
            ]
            for (w, h, d, x, z) in bars {
                let box = SCNBox(width: w, height: d, length: h, chamferRadius: 0.004)
                box.materials = [frame]
                let node = SCNNode(geometry: box)
                node.position = SCNVector3(x, 0.012, z)
                board.addChildNode(node)
            }

            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 42
            camera.camera?.zNear = 0.02
            camera.camera?.zFar = 20
            frameCamera(viewSize: CGSize(width: 390, height: 844))
            scene.rootNode.addChildNode(camera)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 180
            ambient.light?.color = UIColor(white: 0.92, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            func lamp(_ intensity: CGFloat, _ euler: SCNVector3) {
                let node = SCNNode()
                let light = SCNLight()
                light.type = .directional
                light.intensity = intensity
                light.color = UIColor(white: 1, alpha: 1)
                node.light = light
                node.eulerAngles = euler
                scene.rootNode.addChildNode(node)
            }
            lamp(980, SCNVector3(-1.15, 0.15, 0))
            lamp(260, SCNVector3(-0.4, 2.2, 0))
        }

        private func rebuild(cols: Int, rows: Int) {
            for node in shafts { node.removeFromParentNode() }
            for node in caps { node.removeFromParentNode() }
            shafts.removeAll(keepingCapacity: true)
            caps.removeAll(keepingCapacity: true)
            let count = cols * rows
            shafts.reserveCapacity(count)
            caps.reserveCapacity(count)
            for _ in 0..<count {
                let shaft = SCNNode(geometry: shaftGeo)
                let cap = SCNNode(geometry: capGeo)
                board.addChildNode(shaft)
                board.addChildNode(cap)
                shafts.append(shaft)
                caps.append(cap)
            }
            self.cols = cols
            self.rows = rows
        }
    }
}
