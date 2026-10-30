import MessageUI
import SwiftUI

struct ContentView: View {
    @StateObject private var model = BoardModel()
    @State private var showControls = false
    @State private var hideTask: Task<Void, Never>?
    @State private var shareFile: ShareFile?
    @State private var captureNote = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
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
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.togglePinsLock() }
            .onTapGesture { reveal() }
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
        .background(Color(red: 0.05, green: 0.045, blue: 0.04))
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $shareFile) { file in
            ActivityView(items: [file.url])
        }
        .sheet(item: $model.traceMail) { mail in
            TraceMailView(mail: mail) { model.traceMail = nil }
        }
        .overlay(alignment: .top) {
            if let traceStatus = model.traceStatus {
                Text(traceStatus)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("View", selection: Binding(
                get: { model.look },
                set: { model.setLook($0); reveal() }
            )) {
                Text("Chrome").tag(BoardLook.chrome)
                Text("Depth").tag(BoardLook.depth)
            }
            .pickerStyle(.segmented)

            Button {
                reveal()
                model.exportCapture { url in
                    if let url {
                        captureNote = ""
                        shareFile = ShareFile(url: url)
                    } else {
                        captureNote = "No frame yet. Point the screen at something and try again."
                    }
                }
            } label: {
                Text(captureNote.isEmpty ? "Save capture" : captureNote)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))

            Toggle(isOn: Binding(
                get: { model.followsDepth },
                set: { model.setFollowsDepth($0); reveal() }
            )) {
                Text("Follow depth")
                    .font(.caption)
            }
            .tint(Color(white: 0.82))

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
                    in: 5...150,
                    step: 1,
                    onEditingChanged: hold(_:)
                )
            }
            labeled("End", value: "\(model.endCM) cm") {
                Slider(
                    value: Binding(
                        get: { Double(model.endCM) },
                        set: { model.setEndCM(Int($0.rounded())) }
                    ),
                    in: 2...150,
                    step: 1,
                    onEditingChanged: hold(_:)
                )
            }
            Text("Balls rise between Start and End. Scale is how far they travel in that range. In the depth view, blue is farther than both, gray is between them, and red is closer.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
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
            Text("Shake the phone to email a trace with the front camera and depth.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
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

private struct TraceMailView: View {
    let mail: TraceMail
    let onDone: () -> Void

    var body: some View {
        Group {
            if MFMailComposeViewController.canSendMail() {
                MailComposer(mail: mail, onDone: onDone)
            } else {
                ActivityView(items: [mail.report, mail.file])
            }
        }
        .ignoresSafeArea()
    }
}

private struct MailComposer: UIViewControllerRepresentable {
    let mail: TraceMail
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.setToRecipients(["ccamposrdj@gmail.com"])
        controller.setSubject("Pinwell telemetry")
        controller.setMessageBody(mail.report, isHTML: false)
        if let data = try? Data(contentsOf: mail.file) {
            controller.addAttachmentData(data, mimeType: "application/zip", fileName: mail.file.lastPathComponent)
        }
        controller.mailComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true)
            onDone()
        }
    }
}

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
