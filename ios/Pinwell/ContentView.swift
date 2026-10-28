import SwiftUI

struct ContentView: View {
    @StateObject private var model = BoardModel()

    var body: some View {
        ZStack {
            PinSceneView(model: model)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                dock
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pinwell")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                Text("Pins rise inside 25 cm and stay")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(model.nearestCM.map { "\($0) cm" } ?? "—")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(model.posture == "Pressing" ? Color(red: 0.86, green: 0.67, blue: 0.38) : .primary)
                Text(model.posture)
                    .font(.subheadline)
                    .foregroundStyle(model.sliding ? Color(red: 0.86, green: 0.67, blue: 0.38) : .secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(red: 0.07, green: 0.063, blue: 0.055).opacity(0.88))
    }

    private var dock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Density")
                Spacer()
                Text("\(model.cols) × \(model.rows)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(
                value: Binding(
                    get: { Double(model.cols) },
                    set: { model.setCols(Int($0.rounded())) }
                ),
                in: 16...48,
                step: 2
            )
            .tint(Color(red: 0.86, green: 0.67, blue: 0.38))
            Button {
                model.resetPins()
            } label: {
                Text("Reset")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            Text(model.hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }
}
