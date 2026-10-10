import MultiPrintCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Layout

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct InstructionRow: View {
    let symbol: String
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            // Instruction strings use **bold** for the words that matter.
            Text(.init(text)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Large, clickable answer for the wizard's questions.
struct ChoiceCard<Visual: View>: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var visual: Visual

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                visual.frame(height: 92)
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Paper drawings

/// A sheet of paper, either showing printed content or blank.
struct PaperSheet: View {
    var label: String?
    var caption: String?
    var printed = true
    var dashed = false
    var arrowUp: Bool? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white)
            .overlay {
                if printed {
                    VStack(spacing: 4) {
                        if let arrowUp {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .heavy))
                                .rotationEffect(.degrees(arrowUp ? 0 : 180))
                        }
                        if let label { Text(label).font(.system(size: 30, weight: .black, design: .rounded)) }
                        if let caption { Text(caption).font(.system(size: 9, weight: .bold)).tracking(1) }
                        if label == nil {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(0..<5, id: \.self) { i in
                                    Capsule().fill(Color.black.opacity(0.55)).frame(width: i == 4 ? 18 : 30, height: 3)
                                }
                            }
                        }
                    }
                    .foregroundStyle(Color.black)
                    .padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(dashed ? 0.7 : 0.18), style: StrokeStyle(lineWidth: dashed ? 1.5 : 1, dash: dashed ? [4, 3] : []))
            )
            .aspectRatio(0.707, contentMode: .fit)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
    }
}

/// Loops an animation of the stack moving from the output tray to the input tray, turned over or not.
struct ReloadAnimation: View {
    let method: ReloadMethod

    private enum Step: CaseIterable { case reset, rest, lift, place, hold }

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width * 0.52
            ZStack {
                HStack {
                    trayLabel("Output tray", symbol: "tray.and.arrow.up")
                    Spacer()
                    trayLabel("Input tray", symbol: "tray.and.arrow.down")
                }
                .frame(maxHeight: .infinity, alignment: .bottom)

                PhaseAnimator(Step.allCases) { step in
                    let flipped = method == .flipOver && (step == .place || step == .hold)
                    let midFlip = method == .flipOver && step == .lift
                    let angle: Double = flipped ? 180 : (midFlip ? 90 : 0)
                    ZStack {
                        // Back face is mirrored so it reads correctly once rotated.
                        PaperSheet(caption: "BLANK SIDE", printed: true, dashed: true)
                            .overlay(Text("blank side").font(.system(size: 9, weight: .semibold)).foregroundStyle(.black.opacity(0.6)))
                            .scaleEffect(x: -1)
                            .opacity(angle > 90 ? 1 : 0)
                        PaperSheet(label: "1", caption: "PRINTED")
                            .opacity(angle > 90 ? 0 : 1)
                    }
                    .frame(height: geo.size.height * 0.62)
                    .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .scaleEffect(step == .lift ? 1.12 : 1)
                    .offset(x: offset(for: step, travel: travel), y: step == .lift ? -10 : -12)
                } animation: { step in
                    switch step {
                    case .reset: return nil
                    case .rest: return .linear(duration: 0.9)
                    case .lift: return .easeIn(duration: 0.7)
                    case .place: return .easeOut(duration: 0.7)
                    case .hold: return .linear(duration: 1.4)
                    }
                }
            }
        }
        .frame(height: 170)
        .accessibilityLabel(method.instruction)
    }

    private func offset(for step: Step, travel: CGFloat) -> CGFloat {
        switch step {
        case .reset, .rest: return -travel / 2
        case .lift: return 0
        case .place, .hold: return travel / 2
        }
    }

    private func trayLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - Photos

/// A slot for the person's own photo of their printer, e.g. how they load the stack.
struct PhotoSlotView: View {
    @Environment(AppModel.self) private var model
    @Binding var profile: PrinterProfile
    let slot: PhotoSlot
    var editable = true
    @State private var dropTargeted = false

    var body: some View {
        let image = model.photo(slot, of: profile)
        if image == nil && !editable {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(editable ? slot.title : "Your photo: \(slot.title.lowercased())")
                    .font(.subheadline.weight(.semibold))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if editable {
                        HStack {
                            Button("Replace…", action: choose)
                            Button("Remove", role: .destructive) { model.removePhoto(slot, from: &profile) }
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button(action: choose) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.title2)
                            Text("Add your own photo").font(.callout.weight(.medium))
                            Text("Drop an image here or click to choose").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard editable, let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) else { return false }
                model.attachPhoto(url, slot: slot, to: &profile)
                return true
            } isTargeted: { dropTargeted = $0 }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { model.attachPhoto(url, slot: slot, to: &profile) }
    }
}
