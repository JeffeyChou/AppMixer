import AppKit
import SwiftUI

struct MixerPanel: View {
    @ObservedObject var model: MixerModel

    /// The whole panel stays within about half the screen height; the list scrolls beyond that.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(160, screen * 0.5 - 110)   // ~110 pt for header + footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if model.permission == .denied {
                PermissionBanner(model: model)
            }

            let playing = model.playingApps
            let idle = model.idleApps
            if playing.isEmpty && idle.isEmpty {
                Text("No app is playing audio right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                CappedHeightLayout(maxHeight: maxListHeight) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(playing) { row($0) }
                            if !idle.isEmpty {
                                SectionLabel(title: "Idle", count: idle.count)
                                    .padding(.top, playing.isEmpty ? 0 : 4)
                                ForEach(idle) { row($0) }
                            }
                        }
                        .padding(.trailing, 12)   // keep sliders clear of the scroll bar
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }

            Divider()

            Toggle("Show idle audio clients", isOn: $model.showAll)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(14)
        .frame(width: 352)
    }

    /// Rows get plain values and are `.equatable()`, so dragging one slider re-renders only that row.
    private func row(_ app: AudioApp) -> some View {
        AppRow(app: app,
               icon: model.icon(for: app),
               volume: model.volume(app.id),
               muted: model.isMuted(app.id),
               customized: model.isCustomized(app.id),
               error: model.errors[app.id],
               model: model)
            .equatable()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AppMixer").font(.headline)
                Label(model.outputName, systemImage: "hifispeaker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HeaderButton(symbol: model.isAllMuted ? "speaker.wave.2.fill" : "speaker.slash.fill",
                         help: model.isAllMuted ? "Unmute all" : "Mute all playing apps",
                         tint: model.isAllMuted ? .red : nil) {
                model.toggleMuteAll()
            }
            .disabled(!model.canToggleMuteAll)

            HeaderButton(symbol: "arrow.counterclockwise", help: "Reset all apps to 100%") {
                model.resetAll()
            }
            .disabled(!model.hasCustomizations)

            HeaderButton(symbol: "power", help: "Quit AppMixer (⌘Q)") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// Sizes its single child (the ScrollView) to the child's natural content height, but never taller
/// than `maxHeight`; past that the ScrollView scrolls. Pure layout, no measure-then-update round trip.
private struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct SectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            VStack { Divider() }
        }
    }
}

private struct AppRow: View, Equatable {
    let app: AudioApp
    let icon: NSImage
    let volume: Double
    let muted: Bool
    let customized: Bool
    let error: String?
    let model: MixerModel   // only for actions; deliberately not observed

    static func == (a: AppRow, b: AppRow) -> Bool {
        a.app == b.app && a.icon === b.icon && a.volume == b.volume && a.muted == b.muted
            && a.customized == b.customized && a.error == b.error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(app.name).lineLimit(1)
                if app.isPlaying {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Playing audio")
                }
                Spacer()
                Text(muted ? "muted" : "\(Int((volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(muted ? Color.red : Color.secondary)
            }

            HStack(spacing: 6) {
                Button { model.toggleMute(app.id) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(muted ? Color.red : Color.primary)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(muted ? "Unmute" : "Mute")

                Slider(value: Binding(get: { volume },
                                      set: { model.setVolume($0, for: app.id) }),
                       in: 0...MixerModel.maxVolume)
                    .controlSize(.small)
                    .disabled(muted)

                Button { model.reset(app.id) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Reset to 100%")
                .opacity(customized ? 1 : 0)
                .disabled(!customized)
            }

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .opacity(app.isPlaying ? 1 : 0.6)
    }
}

private struct PermissionBanner: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AppMixer needs “System Audio Recording” permission to change per-app volume.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") { model.requestPermissionAgain() }
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
    }
}
