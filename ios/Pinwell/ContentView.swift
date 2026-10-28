import SwiftUI

struct ContentView: View {
    @StateObject private var model = BoardModel()
    @State private var showControls = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            PinSceneView(model: model)
                .ignoresSafeArea()
                .opacity(model.showsDepth ? 0 : 1)
            if model.showsDepth, let image = model.depthImage {
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
        .animation(.easeInOut(duration: 0.35), value: showControls)
        .contentShape(Rectangle())
        .onTapGesture { reveal() }
        .background(Color(red: 0.05, green: 0.045, blue: 0.04))
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("View", selection: Binding(
                get: { model.showsDepth },
                set: { model.setShowsDepth($0); reveal() }
            )) {
                Text("Pins").tag(false)
                Text("Depth").tag(true)
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
