import SceneKit
import SwiftUI

struct PinSceneView: UIViewRepresentable {
    @ObservedObject var model: BoardModel

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = UIColor(red: 0.071, green: 0.063, blue: 0.055, alpha: 1)
        view.antialiasingMode = .multisampling2X
        view.rendersContinuously = true
        view.delegate = context.coordinator
        view.autoenablesDefaultLighting = false
        view.isUserInteractionEnabled = false
        context.coordinator.owner = model
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.owner = model
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
        var owner: BoardModel?
        private let shaftGeo: SCNCylinder
        private let capGeo: SCNCylinder
        private let shaftMat = SCNMaterial()
        private let capMat = SCNMaterial()

        override init() {
            shaftGeo = SCNCylinder(radius: 1, height: 1)
            shaftGeo.radialSegmentCount = 7
            capGeo = SCNCylinder(radius: 1, height: 1)
            capGeo.radialSegmentCount = 10
            super.init()
            metal(shaftMat, rough: 0.46)
            metal(capMat, rough: 0.28)
            shaftGeo.materials = [shaftMat]
            capGeo.materials = [capMat]
            buildStudio()
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let model = owner else { return }
            let dt = last == 0 ? 0 : time - last
            last = time
            let frame = model.step(dt: dt)
            if frame.cols != cols || frame.rows != rows {
                rebuild(cols: frame.cols, rows: frame.rows)
            }
            let n = min(frame.shown.count, shafts.count)
            guard frame.cols > 0, frame.rows > 0 else { return }
            let pitch = min(PinMath.boardW / Float(frame.cols), PinMath.boardH / Float(frame.rows))
            let shaftR = pitch * 0.22
            let capR = pitch * 0.36
            let capT = max(Float(0.008), pitch * 0.42)
            for i in 0..<n {
                let h = PinMath.height(frame.shown[i])
                let x = ((Float(i % frame.cols) + 0.5) / Float(frame.cols)) * PinMath.boardW - PinMath.boardW / 2
                let y = PinMath.boardH / 2 - ((Float(i / frame.cols) + 0.5) / Float(frame.rows)) * PinMath.boardH
                shafts[i].simdPosition = SIMD3(x, y, h * 0.5)
                shafts[i].simdScale = SIMD3(shaftR, h, shaftR)
                caps[i].simdPosition = SIMD3(x, y, h + capT * 0.5)
                caps[i].simdScale = SIMD3(capR, capT, capR)
            }
        }

        private func metal(_ mat: SCNMaterial, rough: CGFloat) {
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = UIColor(red: 0.78, green: 0.80, blue: 0.84, alpha: 1)
            mat.metalness.contents = 0.64
            mat.roughness.contents = rough
        }

        private func buildStudio() {
            board.eulerAngles = SCNVector3(-0.42, 0.08, 0)
            scene.rootNode.addChildNode(board)

            let plate = SCNNode(geometry: SCNPlane(width: CGFloat(PinMath.boardW), height: CGFloat(PinMath.boardH)))
            plate.geometry?.firstMaterial?.lightingModel = .physicallyBased
            plate.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.063, green: 0.055, blue: 0.047, alpha: 1)
            plate.geometry?.firstMaterial?.roughness.contents = 0.9
            plate.geometry?.firstMaterial?.metalness.contents = 0.04
            board.addChildNode(plate)

            let frame = SCNMaterial()
            frame.lightingModel = .physicallyBased
            frame.diffuse.contents = UIColor(red: 0.086, green: 0.075, blue: 0.067, alpha: 1)
            frame.roughness.contents = 0.58
            frame.metalness.contents = 0.22
            let t: CGFloat = 0.062
            let hw = CGFloat(PinMath.boardW) / 2
            let hh = CGFloat(PinMath.boardH) / 2
            let bars: [(CGFloat, CGFloat, CGFloat, Float, Float)] = [
                (CGFloat(PinMath.boardW) + t * 2, t, 0.07, 0, Float(hh + t / 2)),
                (CGFloat(PinMath.boardW) + t * 2, t, 0.07, 0, -Float(hh + t / 2)),
                (t, CGFloat(PinMath.boardH), 0.07, -Float(hw + t / 2), 0),
                (t, CGFloat(PinMath.boardH), 0.07, Float(hw + t / 2), 0),
            ]
            for (w, h, d, x, y) in bars {
                let box = SCNBox(width: w, height: h, length: d, chamferRadius: 0.004)
                box.materials = [frame]
                let node = SCNNode(geometry: box)
                node.position = SCNVector3(x, y, 0)
                board.addChildNode(node)
            }

            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 32
            camera.camera?.zNear = 0.04
            camera.camera?.zFar = 20
            camera.position = SCNVector3(0.95, 0.42, 2.25)
            camera.look(at: SCNVector3(0, -0.02, 0.05))
            scene.rootNode.addChildNode(camera)

            func lamp(_ intensity: CGFloat, _ color: UIColor, _ euler: SCNVector3) {
                let node = SCNNode()
                let light = SCNLight()
                light.type = .directional
                light.intensity = intensity
                light.color = color
                node.light = light
                node.eulerAngles = euler
                scene.rootNode.addChildNode(node)
            }
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 220
            ambient.light?.color = UIColor(red: 1, green: 0.95, blue: 0.88, alpha: 1)
            scene.rootNode.addChildNode(ambient)
            lamp(1100, UIColor(red: 1, green: 0.96, blue: 0.9, alpha: 1), SCNVector3(-0.9, 0.45, 0))
            lamp(420, UIColor(red: 0.82, green: 0.88, blue: 0.95, alpha: 1), SCNVector3(-0.2, -1.2, 0))
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
                shaft.simdEulerAngles = SIMD3(Float.pi / 2, 0, 0)
                let cap = SCNNode(geometry: capGeo)
                cap.simdEulerAngles = SIMD3(Float.pi / 2, 0, 0)
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
