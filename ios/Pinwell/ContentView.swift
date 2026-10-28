import SwiftUI

struct ContentView: View {
    @StateObject private var model = BoardModel()
    @State private var showControls = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            PinSceneView(model: model)
                .ignoresSafeArea()
                .opacity(model.look == .depth ? 0 : 1)
            if model.look == .depth, let image = model.depthImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            controls
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
        }
        .overlay(alignment: .topTrailing) {
            if model.pinsLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(.top, 10)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showControls)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.togglePinsLock() }
        .onTapGesture { reveal() }
        .background(Color(red: 0.05, green: 0.045, blue: 0.04))
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("View", selection: Binding(
                get: { model.look },
                set: { model.setLook($0); reveal() }
            )) {
                Text("Pins").tag(BoardLook.pins)
                Text("Chrome").tag(BoardLook.chrome)
                Text("Depth").tag(BoardLook.depth)
            }
            .pickerStyle(.segmented)

            labeled("Density", value: "\(model.cols)") {
                Slider(
                    value: Binding(
                        get: { Double(model.cols) },
                        set: { model.setCols(Int($0.rounded())) }
                    ),
                    in: 16...48,
                    step: 2,
                    onEditingChanged: hold(_:)
                )
            }
            labeled("Start", value: "\(model.startCM) cm") {
                Slider(
                    value: Binding(
                        get: { Double(model.startCM) },
                        set: { model.setStartCM(Int($0.rounded())) }
                    ),
                    in: 10...100,
                    step: 1,
                    onEditingChanged: hold(_:)
                )
            }
            labeled("Depth", value: "\(model.spanCM) cm") {
                Slider(
                    value: Binding(
                        get: { Double(model.spanCM) },
                        set: { model.setSpanCM(Int($0.rounded())) }
                    ),
                    in: 2...40,
                    step: 1,
                    onEditingChanged: hold(_:)
                )
            }
            labeled("Scale", value: String(format: "%.1f", model.pinScale)) {
                Slider(
                    value: Binding(
                        get: { model.pinScale },
                        set: { model.setPinScale($0) }
                    ),
                    in: 0.1...2.0,
                    step: 0.1,
                    onEditingChanged: hold(_:)
                )
            }
            if model.look == .chrome {
                labeled("Reflect", value: "\(Int((model.reflection * 100).rounded()))%") {
                    Slider(
                        value: Binding(
                            get: { model.reflection },
                            set: { model.setReflection($0) }
                        ),
                        in: 0...1,
                        step: 0.05,
                        onEditingChanged: hold(_:)
                    )
                }
                labeled("Blur", value: "\(Int((model.blur * 100).rounded()))%") {
                    Slider(
                        value: Binding(
                            get: { model.blur },
                            set: { model.setBlur($0) }
                        ),
                        in: 0...1,
                        step: 0.05,
                        onEditingChanged: hold(_:)
                    )
                }
            }
        }
        .tint(Color(white: 0.82))
        .padding(16)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    private func labeled<Control: View>(_ title: String, value: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
            control()
        }
    }

    private func hold(_ editing: Bool) {
        if editing {
            showControls = true
            hideTask?.cancel()
        } else {
            scheduleHide()
        }
    }

    private func reveal() {
        showControls = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            showControls = false
        }
    }
}
