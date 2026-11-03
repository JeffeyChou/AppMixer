import AppKit
import SwiftUI

struct MixerPanel: View {
    @ObservedObject var model: MixerModel

    /// The whole panel stays within about half the screen height; the app list scrolls beyond that.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(160, screen * 0.5 - 190)   // ~190 pt for header, output card and footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            OutputCard(deviceSymbol: model.systemDevice?.symbol ?? "hifispeaker",
                       deviceName: model.systemOutputName,
                       isSharing: model.isSharing,
                       volume: model.systemVolume,
                       muted: model.systemMuted,
                       error: model.outputError,
                       model: model)
                .equatable()

            if model.permission == .denied {
                PermissionBanner(model: model)
            }

            let playing = model.playingApps
            let idle = model.idleApps
            if playing.isEmpty && idle.isEmpty {
                Text("No app is playing audio right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                CappedHeightLayout(maxHeight: maxListHeight) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(playing) { app in
                                row(app)
                                if model.expandedEQ == app.id { eqEditor(app) }
                            }
                            if !idle.isEmpty {
                                SectionLabel(title: "Idle", count: idle.count)
                                    .padding(.top, playing.isEmpty ? 0 : 4)
                                ForEach(idle) { app in
                                    row(app)
                                    if model.expandedEQ == app.id { eqEditor(app) }
                                }
                            }
                        }
                        .padding(.trailing, 12)   // keep controls clear of the scroll bar
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
        .frame(width: 360)
    }

    /// Rows get plain values and are `.equatable()`, so dragging one slider re-renders only that row.
    private func row(_ app: AudioApp) -> some View {
        let routed = model.routedDevice(app.id)
        return AppRow(app: app,
                      icon: model.icon(for: app),
                      volume: model.volume(app.id),
                      muted: model.isMuted(app.id),
                      customized: model.isCustomized(app.id),
                      error: model.errors[app.id],
                      routedName: routed?.name,
                      routedSymbol: routed?.symbol,
                      eqActive: model.isEQActive(app.id),
                      eqExpanded: model.expandedEQ == app.id,
                      model: model)
            .equatable()
    }

    private func eqEditor(_ app: AudioApp) -> some View {
        EQEditor(id: app.id, gains: model.eq(app.id), isOn: model.isEQOn(app.id), model: model)
            .equatable()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("AppMixer").font(.headline)
            Spacer()
            IconButton(symbol: model.isAllMuted ? "speaker.wave.2.fill" : "speaker.slash.fill",
                       help: model.isAllMuted ? "Unmute all" : "Mute all playing apps",
                       tint: model.isAllMuted ? .red : nil, size: 13) {
                model.toggleMuteAll()
            }
            .disabled(!model.canToggleMuteAll)

            IconButton(symbol: "arrow.counterclockwise", help: "Reset all apps (volume, EQ, output)", size: 13) {
                model.resetAll()
            }
            .disabled(!model.hasCustomizations)

            IconButton(symbol: "power", help: "Quit AppMixer (⌘Q)", size: 13) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Menus (built on click, see PopupMenu)

enum Menus {
    static func systemOutput(_ model: MixerModel) {
        var items: [PopupMenu.Item] = [.header("System Output")]
        for d in model.devices {
            items.append(.init(title: d.name, symbol: d.symbol, checked: d.uid == model.systemDeviceUID) {
                model.selectSystemOutput(d.uid)
            })
        }
        PopupMenu.show(items)
    }

    static func share(_ model: MixerModel) {
        var items: [PopupMenu.Item] = [.header("Also play on")]
        let others = model.devices.filter { $0.uid != model.systemDeviceUID }
        if others.isEmpty {
            items.append(.init(title: "No other output devices"))
        }
        for d in others {
            items.append(.init(title: d.name, symbol: d.symbol, checked: model.shareUIDs.contains(d.uid)) {
                model.toggleShare(d.uid)
            })
        }
        if model.isSharing {
            items.append(.separator)
            items.append(.init(title: "Stop Sharing", symbol: "xmark.circle") { model.stopSharing() })
        }
        PopupMenu.show(items)
    }

    static func appOutput(_ model: MixerModel, _ app: AudioApp) {
        let current = model.appOutputs[app.id]
        var items: [PopupMenu.Item] = [.header("Play \(app.name) on")]
        items.append(.init(title: "System Output — \(model.systemOutputName)", symbol: "macwindow",
                           checked: current == nil) {
            model.setOutput(nil, for: app.id)
        })
        items.append(.separator)
        for d in model.devices {
            items.append(.init(title: d.name, symbol: d.symbol, checked: current == d.uid) {
                model.setOutput(d.uid, for: app.id)
            })
        }
        PopupMenu.show(items)
    }

    static func eqPresets(_ model: MixerModel, _ id: String, current: [Double]) {
        let currentName = EQ.presetName(for: current)
        var items: [PopupMenu.Item] = [.header("Presets")]
        for preset in EQ.presets {
            items.append(.init(title: preset.name, checked: preset.name == currentName) {
                model.setEQ(preset.gains, for: id)
            })
        }
        PopupMenu.show(items)
    }
}

// MARK: - Output card

private struct OutputCard: View, Equatable {
    let deviceSymbol: String
    let deviceName: String
    let isSharing: Bool
    let volume: Float?
    let muted: Bool
    let error: String?
    let model: MixerModel

    static func == (a: OutputCard, b: OutputCard) -> Bool {
        a.deviceSymbol == b.deviceSymbol && a.deviceName == b.deviceName && a.isSharing == b.isSharing
            && a.volume == b.volume && a.muted == b.muted && a.error == b.error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { Menus.systemOutput(model) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: deviceSymbol)
                            .frame(width: 20)
                        Text(deviceName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose the system output device")

                Spacer(minLength: 6)

                Button { Menus.share(model) } label: {
                    Label(isSharing ? "Sharing" : "Share", systemImage: "plus.square.on.square")
                        .font(.caption)
                        .foregroundStyle(isSharing ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Share Audio: also play the system output on other devices")
            }

            HStack(spacing: 4) {
                Button { model.toggleSystemMute() } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(muted ? Color.red : Color.primary)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(muted ? "Unmute system output" : "Mute system output")
                .disabled(volume == nil)

                Slider(value: Binding(get: { Double(volume ?? 0) },
                                      set: { model.setSystemVolume(Float($0)) }),
                       in: 0...1)
                    .controlSize(.small)
                    .disabled(volume == nil)

                Text(volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.055)))
    }
}

// MARK: - App row

private struct AppRow: View, Equatable {
    let app: AudioApp
    let icon: NSImage
    let volume: Double
    let muted: Bool
    let customized: Bool
    let error: String?
    let routedName: String?
    let routedSymbol: String?
    let eqActive: Bool
    let eqExpanded: Bool
    let model: MixerModel   // only for actions; deliberately not observed

    static func == (a: AppRow, b: AppRow) -> Bool {
        a.app == b.app && a.icon === b.icon && a.volume == b.volume && a.muted == b.muted
            && a.customized == b.customized && a.error == b.error && a.routedName == b.routedName
            && a.routedSymbol == b.routedSymbol && a.eqActive == b.eqActive && a.eqExpanded == b.eqExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(app.name)
                    .lineLimit(1)
                    .layoutPriority(1)
                if app.isPlaying {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Playing audio")
                }
                if let routedName {
                    Label(routedName, systemImage: "arrow.turn.down.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .help("Playing on \(routedName)")
                }
                Spacer(minLength: 4)
                Text(muted ? "muted" : "\(Int((volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(muted ? Color.red : Color.secondary)
            }

            HStack(spacing: 2) {
                IconButton(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           help: muted ? "Unmute" : "Mute",
                           tint: muted ? .red : nil) {
                    model.toggleMute(app.id)
                }

                Slider(value: Binding(get: { volume },
                                      set: { model.setVolume($0, for: app.id) }),
                       in: 0...MixerModel.maxVolume)
                    .controlSize(.small)
                    .disabled(muted)
                    .padding(.trailing, 4)

                IconButton(symbol: routedSymbol ?? "hifispeaker",
                           help: routedName.map { "Output: \($0)" } ?? "Output: System Output",
                           tint: routedName != nil ? .accentColor : nil) {
                    Menus.appOutput(model, app)
                }

                IconButton(symbol: "slider.horizontal.3",
                           help: "Equalizer",
                           tint: eqActive ? .accentColor : nil,
                           highlighted: eqExpanded) {
                    model.toggleEQExpanded(app.id)
                }

                IconButton(symbol: "arrow.counterclockwise", help: "Reset volume, EQ and output") {
                    model.reset(app.id)
                }
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

// MARK: - Equalizer

private struct EQEditor: View, Equatable {
    let id: String
    let gains: [Double]
    let isOn: Bool
    let model: MixerModel

    static func == (a: EQEditor, b: EQEditor) -> Bool {
        a.id == b.id && a.gains == b.gains && a.isOn == b.isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { Menus.eqPresets(model, id, current: gains) } label: {
                    HStack(spacing: 4) {
                        Text(EQ.presetName(for: gains) ?? "Custom")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("EQ presets")

                Spacer()

                Toggle("EQ", isOn: Binding(get: { isOn }, set: { _ in model.toggleEQOn(id) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
            }
            EQGraph(gains: gains, isOn: isOn) { band, gain in
                model.setEQBand(band, gain: gain, for: id)
            }
            .frame(height: 104)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// One Canvas: grid, response curve and 10 draggable band handles. Drag anywhere; the nearest band
/// (by x) follows the pointer vertically.
private struct EQGraph: View {
    let gains: [Double]
    let isOn: Bool
    let onChange: (Int, Double) -> Void
    @State private var dragBand: Int?

    private let inset = EdgeInsets(top: 6, leading: 12, bottom: 16, trailing: 12)
    private static let span = log2(EQ.frequencies.last! / EQ.frequencies.first!)

    private func x(_ frequency: Double, _ size: CGSize) -> CGFloat {
        let t = log2(frequency / EQ.frequencies.first!) / Self.span
        return inset.leading + CGFloat(t) * (size.width - inset.leading - inset.trailing)
    }

    private func y(_ db: Double, _ size: CGSize) -> CGFloat {
        let h = size.height - inset.top - inset.bottom
        return inset.top + h * CGFloat(1 - (min(max(db, -EQ.maxGain), EQ.maxGain) + EQ.maxGain) / (2 * EQ.maxGain))
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let tint = isOn ? Color.accentColor : Color.secondary
            Canvas { ctx, size in
                // Grid: ±12, ±6, 0 dB.
                for db in stride(from: -12.0, through: 12.0, by: 6.0) {
                    var line = Path()
                    line.move(to: CGPoint(x: inset.leading, y: y(db, size)))
                    line.addLine(to: CGPoint(x: size.width - inset.trailing, y: y(db, size)))
                    ctx.stroke(line, with: .color(.primary.opacity(db == 0 ? 0.22 : 0.08)), lineWidth: 1)
                }

                // Response curve.
                var curve = Path()
                let steps = 72
                for i in 0...steps {
                    let f = EQ.frequencies.first! * pow(2, Self.span * Double(i) / Double(steps))
                    let p = CGPoint(x: x(f, size), y: y(EQ.response(gains: gains, at: f), size))
                    if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                }
                var fill = curve
                fill.addLine(to: CGPoint(x: size.width - inset.trailing, y: y(0, size)))
                fill.addLine(to: CGPoint(x: inset.leading, y: y(0, size)))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(tint.opacity(0.12)))
                ctx.stroke(curve, with: .color(tint), lineWidth: 1.5)

                // Band handles + labels.
                for (i, f) in EQ.frequencies.enumerated() {
                    let r: CGFloat = dragBand == i ? 5 : 3.5
                    let c = CGPoint(x: x(f, size), y: y(gains[i], size))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(tint))
                    ctx.draw(Text(EQ.labels[i]).font(.system(size: 8)).foregroundStyle(.secondary),
                             at: CGPoint(x: c.x, y: size.height - 6))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragBand == nil {
                            let w = size.width - inset.leading - inset.trailing
                            let t = (value.startLocation.x - inset.leading) / max(w, 1)
                            dragBand = min(max(Int((t * CGFloat(EQ.bandCount - 1)).rounded()), 0), EQ.bandCount - 1)
                        }
                        let h = size.height - inset.top - inset.bottom
                        let db = EQ.maxGain - Double((value.location.y - inset.top) / max(h, 1)) * 2 * EQ.maxGain
                        onChange(dragBand!, db)
                    }
                    .onEnded { _ in dragBand = nil }
            )
        }
        .help("Drag a band up or down. Presets reset the curve.")
    }
}

// MARK: - Small pieces

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

/// Borderless icon button with a comfortable hit area.
private struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    var highlighted = false
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(highlighted ? Color.primary.opacity(0.1) : .clear))
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

private struct PermissionBanner: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AppMixer needs “System Audio Recording” permission to change per-app audio.")
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
