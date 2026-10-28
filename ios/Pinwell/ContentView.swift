import SwiftUI

struct ContentView: View {
    @StateObject private var model = BoardModel()
    @State private var showSlider = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            PinSceneView(model: model)
                .ignoresSafeArea()
            Slider(
                value: Binding(
                    get: { Double(model.cols) },
                    set: { model.setCols(Int($0.rounded())) }
                ),
                in: 16...48,
                step: 2,
                onEditingChanged: { editing in
                    if editing {
                        showSlider = true
                        hideTask?.cancel()
                    } else {
                        scheduleHide()
                    }
                }
            )
            .tint(Color(white: 0.82))
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
            .opacity(showSlider ? 1 : 0)
            .allowsHitTesting(showSlider)
        }
        .animation(.easeInOut(duration: 0.4), value: showSlider)
        .contentShape(Rectangle())
        .onTapGesture { revealSlider() }
        .background(Color(red: 0.05, green: 0.045, blue: 0.04))
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func revealSlider() {
        showSlider = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            guard !Task.isCancelled else { return }
            showSlider = false
        }
    }
}
