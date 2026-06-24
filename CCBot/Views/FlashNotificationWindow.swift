// CCBot/Views/FlashNotificationWindow.swift
import AppKit
import SwiftUI

@MainActor
final class FlashNotificationWindow {
    static let shared = FlashNotificationWindow()

    private static let cardSize = CGSize(width: 380, height: 96)
    private static let displayDuration: TimeInterval = 5.7

    private let panel: NSPanel
    private let model = FlashCardModel()
    private var dismissTask: Task<Void, Never>?

    private init() {
        let rect = NSRect(origin: .zero, size: Self.windowSize)
        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary, .transient]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: FlashCardView(model: model))
        hosting.frame = rect
        panel.contentView = hosting
    }

    private static var windowSize: CGSize {
        // Add padding around the card so shadow/scale/glow animations aren't clipped.
        CGSize(width: cardSize.width + 160, height: cardSize.height + 160)
    }

    static func show(title: String, body: String) {
        shared.present(title: title, body: body)
    }

    private func present(title: String, body: String) {
        positionOnScreen()
        panel.orderFrontRegardless()
        model.update(title: title, body: body)

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.displayDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.model.dismiss()
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.panel.orderOut(nil)
            }
        }
    }

    private func positionOnScreen() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let size = Self.windowSize
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

@MainActor
private final class FlashCardModel: ObservableObject {
    @Published var title: String = ""
    @Published var body: String = ""
    @Published var isVisible: Bool = false
    @Published var pulseToken: UUID = UUID()

    func update(title: String, body: String) {
        self.title = title
        self.body = body
        self.isVisible = true
        self.pulseToken = UUID()
    }

    func dismiss() {
        self.isVisible = false
    }
}

private struct FlashCardView: View {
    @ObservedObject var model: FlashCardModel
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.0

    var body: some View {
        ZStack {
            glow
            card
        }
        .scaleEffect((model.isVisible ? 1.0 : 0.94) * pulseScale)
        .opacity(model.isVisible ? 1.0 : 0.0)
        .offset(y: model.isVisible ? 0 : -10)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.pulseToken) { _ in
            triggerPulse()
        }
        .onAppear {
            triggerPulse()
        }
    }

    private var glow: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(Color.accentColor, lineWidth: 18)
            .frame(width: 380 + 10, height: 96 + 10)
            .blur(radius: 22)
            .opacity(glowOpacity)
            .allowsHitTesting(false)
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("CCBot")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(model.body)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 380, height: 96, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(glowOpacity), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
    }

    private var appIcon: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 44, height: 44)
    }

    private func triggerPulse() {
        pulseScale = 1.0
        glowOpacity = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeInOut(duration: 0.5).repeatCount(10, autoreverses: true)) {
                pulseScale = 1.025
                glowOpacity = 0.85
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    pulseScale = 1.0
                    glowOpacity = 0.0
                }
            }
        }
    }
}
