import SwiftUI
import AppKit

@main
struct SoundShelfApp: App {
    @NSApplicationDelegateAdaptor(SoundShelfAppDelegate.self) private var appDelegate
    init() {
        if CommandLine.arguments.contains("--diagnose") {
            let audio = AudioController()
            audio.refresh()
            let outputs = audio.devices.map { device -> [String: Any] in
                var result: [String: Any] = ["id": device.id, "name": device.name, "selected": device.id == audio.selected]
                if let volume = device.volume { result["volume"] = volume }
                return result
            }
            var result: [String: Any] = ["outputs": outputs]
            if let error = audio.error { result["error"] = error }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(audio.error == nil ? 0 : 1)
        }
    }
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct ShelfView: View {
    @ObservedObject var model: MediaModel
    @ObservedObject var shelfMute: ShelfMuteController
    @ObservedObject var macMute: MacMuteController
    @ObservedObject var microphoneMute: MicrophoneMuteController
    var restartApp: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ShelfPalette { ShelfPalette(dark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeader("Sound")
                    if model.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No players yet").font(.system(size: 12, weight: .medium))
                            Text("Connect a browser or music app.").font(.system(size: 10)).foregroundStyle(palette.secondary)
                            Button("Connect browser") { model.openGuide() }
                                .font(.system(size: 11))
                        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(model.sources) { source in
                                    PlayerRow(source: source, model: model, masterMuted: shelfMute.isMuted)
                                        .overlay(alignment: .bottom) { rowDivider }
                                }
                            }
                        }
                    }
                }.frame(minWidth: 0, maxWidth: .infinity)
                Rectangle().fill(palette.divider).frame(width: 1)
                VStack(alignment: .leading, spacing: 0) {
                    columnHeader("Mic")
                    if model.microphoneSources.isEmpty {
                        Text("No microphone sources")
                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(model.microphoneSources) { source in
                                    MicrophoneRow(source: source, model: model, masterMuted: microphoneMute.isMuted)
                                        .overlay(alignment: .bottom) { rowDivider }
                                }
                            }
                        }
                    }
                }.frame(minWidth: 0, maxWidth: .infinity)
            }.frame(height: 32 + max(120, min(CGFloat(max(model.sources.count, model.microphoneSources.count)) * PlayerRow.height, PlayerRow.height * 7)))
                // Share the row's bottom pixel instead of adding a second line below it.
                .overlay(alignment: .bottom) { rowDivider }
            HStack(alignment: .top, spacing: 0) {
                soundFooter
                Rectangle().fill(palette.divider).frame(width: 1)
                microphoneFooter
            }.frame(height: 92)
            if let error = macMute.error ?? model.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button { model.error = nil; macMute.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }.padding(8)
            }
        }
        .frame(width: 520)
        .foregroundStyle(palette.text)
        .background(palette.background)
        // NSPopover already clips and outlines its window. A second rounded
        // mask leaves visible crescents between our content and the native bezel.
        .contextMenu {
            Toggle("Connect Spotify & Music", isOn: $model.nativeEnabled)
            Button("Browser setup…") { model.openGuide() }
            Divider()
            Button("Restart SoundShelf") { restartApp() }
            Button("Quit SoundShelf") { NSApplication.shared.terminate(nil) }
        }
    }
    private var soundFooter: some View {
        VStack(spacing: 8) {
            Button { macMute.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "apple.logo").font(.system(size: 15))
                    Text(macMute.isMuted ? "Restore Mac Sound" : "Silence Mac")
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(macMute.isMuted ? palette.red : palette.blue)
                .background(palette.buttonBackground, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
            Button { shelfMute.toggle() } label: {
                HStack(spacing: 6) {
                    Image(nsImage: SoundShelfIcon.menuBar).resizable().frame(width: 16, height: 16)
                    Text(shelfMute.isMuted ? "Restore SoundShelf" : "Silence SoundShelf")
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(shelfMute.isMuted ? palette.red : palette.blue)
                .background(palette.buttonBackground, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
                .disabled(shelfMute.isBusy || !model.busySourceIDs.isEmpty || (!shelfMute.isMuted && model.sources.isEmpty))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(10)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private var microphoneFooter: some View {
        VStack(spacing: 8) {
            Button { microphoneMute.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: microphoneMute.isMuted ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 14))
                    Text(microphoneMute.isMuted ? "Unmute Microphones" : "Mute Microphones")
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(microphoneMute.isMuted ? palette.red : palette.blue)
                .background(palette.buttonBackground, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
                .disabled(microphoneMute.isBusy || !model.busyMicrophoneIDs.isEmpty || (!microphoneMute.isMuted && !microphoneMute.canMute))
                .help(microphoneMute.isMuted ? "Unmute only microphones muted by this button in this app session." : "Mute supported microphone sources. Unsupported sources are unchanged.")
            Text("Supported sources only")
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(10)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private func columnHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) { rowDivider }
    }
    private var rowDivider: some View {
        Rectangle().fill(palette.divider).frame(height: 1).allowsHitTesting(false)
    }

}

struct PlayerRow: View {
    static let height: CGFloat = 60
    let source: MediaSource
    @ObservedObject var model: MediaModel
    var masterMuted = false
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ShelfPalette { ShelfPalette(dark: colorScheme == .dark) }

    private var soundColor: Color {
        guard let muted = source.muted else { return palette.secondary }
        return muted ? palette.red : palette.blue
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { model.command(source, action: "focus") } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName ?? source.title).font(.system(size: 12, weight: source.playing ? .semibold : .medium)).lineLimit(1)
                    Text(source.title == source.displayName ? source.subtitle : source.title).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .foregroundStyle(palette.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(source.nativeApp == nil ? "Open this browser tab" : "Open this app")
            .accessibilityLabel("Open \(source.title) in \(source.subtitle)")
            if source.supportsPlayback {
            Button { model.command(source, action: source.playing ? "pause" : "play") } label: {
                Image(systemName: source.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(source.playing ? palette.green : palette.text)
                    .frame(width: 27, height: 30)
                    .background(source.playing ? palette.greenBackground : palette.buttonBackground, in: Circle())
                    .contentShape(Circle())
            }.buttonStyle(.plain).help(source.playing ? "Pause" : "Play")
                .disabled(model.busySourceIDs.contains(source.id))
                .accessibilityLabel("\(source.playing ? "Pause" : "Play") \(source.title)")
            }
            Button { model.command(source, action: "mute", value: source.muted == true ? 0 : 1) } label: {
                Image(systemName: source.muted == true ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 13)).foregroundStyle(soundColor)
                    .frame(width: 25, height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(masterMuted || source.muted == nil || model.busySourceIDs.contains(source.id))
                .help(source.muted == true ? "Restore sound" : "Silence")
                .accessibilityLabel("\(source.muted == true ? "Restore sound" : "Silence") \(source.title)")
        }
        .frame(height: 32)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(source.playing ? palette.activeBackground : Color.clear)
    }
}

struct MicrophoneRow: View {
    let source: MicrophoneSource
    @ObservedObject var model: MediaModel
    var masterMuted = false
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ShelfPalette { ShelfPalette(dark: colorScheme == .dark) }
    private var available: Bool { source.controllable && source.state != .unknown }
    private var status: String {
        guard available else { return "Microphone status unavailable" }
        return source.state == .enabled ? "Microphone unmuted · click to mute" : "Microphone muted · click to unmute"
    }
    var body: some View {
        HStack(spacing: 6) {
            Button { model.microphoneCommand(source, focus: true) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(source.subtitle).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .foregroundStyle(palette.text).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open \(source.title)")
                .accessibilityLabel("Open \(source.title), \(source.subtitle)")
            Button { model.microphoneCommand(source) } label: {
                Image(systemName: available && source.state == .disabled ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(!available ? palette.secondary : source.state == .enabled ? palette.green : palette.red)
                    .frame(width: 28, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .disabled(masterMuted || !available || model.busyMicrophoneIDs.contains(source.id))
                .help(model.busyMicrophoneIDs.contains(source.id) ? "Updating microphone…" : status)
                .accessibilityLabel("\(source.title): \(status)")
        }
        .frame(height: 32).padding(.horizontal, 12).padding(.vertical, 14)
    }
}

/// Opaque surfaces and status colors tuned for each system appearance.
private struct ShelfPalette {
    let dark: Bool

    var background: Color { color(0xFFFFFF, 0x292D33) }
    var activeBackground: Color { color(0xF0F4F8, 0x3A4048) }
    var buttonBackground: Color { color(0xEDF0F4, 0x464D57) }
    var greenBackground: Color { color(0xE5F4E9, 0x294C38) }
    var text: Color { color(0x20252B, 0xF4F6F8) }
    var secondary: Color { color(0x606872, 0xBAC2CE) }
    var divider: Color { color(0xDDE2E8, 0x535B66) }
    var green: Color { color(0x187B37, 0x7AE39A) }
    var blue: Color { color(0x0964CE, 0x80BDFF) }
    var red: Color { color(0xC32E36, 0xFF9296) }

    private func color(_ light: UInt32, _ darkValue: UInt32) -> Color {
        let value = dark ? darkValue : light
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }
}
