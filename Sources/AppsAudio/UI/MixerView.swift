import AppKit
import SwiftUI

struct MixerView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(.tint)
            Text("AppsAudio")
                .font(.headline)
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh app list")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let groups = model.groups
        if groups.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "speaker.slash")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("No apps are playing audio")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(groups) { group in
                        AppRow(model: model, group: group)
                        if group.id != groups.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
        }
    }

    private var footer: some View {
        HStack {
            Text("Muting affects speakers only — recording still captures the app.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Menu {
                Button("Reset all volumes", action: model.resetAll)
                Divider()
                Button("Quit AppsAudio") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct AppRow: View {
    @ObservedObject var model: MixerModel
    let group: AppGroup

    var body: some View {
        let setting = model.setting(for: group)
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Button {
                        model.toggleMuted(for: group)
                    } label: {
                        Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(setting.muted ? Color.red : Color.secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)

                    Slider(
                        value: Binding(
                            get: { Double(setting.gain) },
                            set: { model.setGain(Float($0), for: group) }
                        ),
                        in: 0...1
                    )
                    .disabled(setting.muted)
                    .controlSize(.small)

                    Text("\(Int((setting.muted ? 0 : setting.gain) * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var icon: some View {
        if let nsImage = group.icon {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 20))
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
        }
    }
}
