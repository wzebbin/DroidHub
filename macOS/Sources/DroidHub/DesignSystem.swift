import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DroidHubCore

enum HubStyle {
    struct Palette {
        let ink: UInt32
        let muted: UInt32
        let sidebar: UInt32
        let canvas: UInt32
        let selection: UInt32
    }

    private static let light = Palette(ink: 0x30343B, muted: 0x5D6673, sidebar: 0xF0F1F3,
                                       canvas: 0xFFFFFF, selection: 0xDDE7F2)
    private static let dark = Palette(ink: 0xE7E9EC, muted: 0xB3BBC7, sidebar: 0x292C30,
                                      canvas: 0x202225, selection: 0x354760)

    static let ink = adaptive(\.ink)
    static let muted = adaptive(\.muted)
    static let sidebar = adaptive(\.sidebar)
    static let canvas = adaptive(\.canvas)
    static let well = adaptive(0xF7F8FA, 0x272A2E)
    static let selection = adaptive(\.selection)
    static let sidebarSelection = adaptive(0xE0F0FD, dark.selection)
    static let line = adaptive(0xE1E4E8, 0x3A3E44)
    static let accent = adaptive(0x3477B3, 0xADC5E5)
    static let workspaceTint = accent.opacity(0.065)
    static let workspaceInset: CGFloat = 24
    static let controlBarHeight: CGFloat = 46
    static let onAccent = adaptive(0xFFFFFF, 0x1F3046)
    static let green = adaptive(0x367348, 0x86C994)
    static let error = adaptive(0xA13F49, 0xF199A2)
    static let folder = adaptive(0xB3C7DE, 0x536D89)
    static let onFolder = adaptive(0x47617D, 0xE5EFFA)
    static let deviceSurface = adaptive(0xEDF4FA, 0x263544)
    static let errorSurface = adaptive(0xFBEEF0, 0x39292F)

    static func previewColor(_ color: KeyPath<Palette, UInt32>, dark: Bool) -> Color {
        Color(nsColor: srgb((dark ? Self.dark : light)[keyPath: color]))
    }

    private static func adaptive(_ color: KeyPath<Palette, UInt32>) -> Color {
        adaptive(light[keyPath: color], dark[keyPath: color])
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return srgb(hex)
        })
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

struct QuietIconButton: View {
    let symbol: String
    let help: String
    var selected = false
    var height: CGFloat = 29
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(selected ? HubStyle.ink : HubStyle.muted)
                .frame(width: 29, height: height)
                .background(selected ? HubStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct ToolbarAction: View {
    let title: String
    let symbol: String
    var prominent = false
    var height: CGFloat = 27
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .regular))
                .padding(.horizontal, 10).frame(height: height)
                .foregroundStyle(prominent && enabled ? HubStyle.onAccent : HubStyle.ink.opacity(enabled ? 1 : 0.35))
                .background(prominent && enabled ? HubStyle.accent : HubStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(prominent && enabled ? HubStyle.accent : HubStyle.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct FileSheetHeading: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title).font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        } icon: {
            Image(systemName: symbol).foregroundStyle(HubStyle.accent)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct FileSheetActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 12) {
            Divider().overlay(HubStyle.line)
            HStack(spacing: 8) { content }
        }
    }
}

extension View {
    func fileSheet(width: CGFloat) -> some View {
        padding(HubStyle.workspaceInset)
            .frame(width: width)
            .foregroundStyle(HubStyle.ink)
            .tint(HubStyle.accent)
            .background(HubStyle.canvas)
    }
}

struct LibrarySearchField: View {
    @Environment(\.l10n) private var l10n
    let placeholder: String
    @Binding var query: String
    var focus: FocusState<Bool>.Binding? = nil
    var width: CGFloat = 170
    var height: CGFloat = 26

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(HubStyle.muted).accessibilityHidden(true)
            if let focus {
                field.focused(focus)
            } else {
                field
            }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(HubStyle.muted)
                }
                .buttonStyle(.plain).accessibilityLabel(l10n.text("清除搜索"))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9).frame(width: width, height: height)
        .background(HubStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HubStyle.line).allowsHitTesting(false))
    }

    private var field: some View {
        ZStack(alignment: .leading) {
            if query.isEmpty {
                Text(placeholder).foregroundStyle(HubStyle.muted).lineLimit(1)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
            TextField(placeholder, text: $query, prompt: Text(""))
                .labelsHidden().textFieldStyle(.plain).foregroundStyle(HubStyle.ink)
                .accessibilityLabel(placeholder)
        }
    }
}

struct FileGlyph: View {
    let file: DeviceFile
    var size: CGFloat = 64
    var body: some View {
        Group {
            if file.isDirectory {
                ZStack {
                    Image(systemName: "folder.fill").resizable().scaledToFit()
                        .foregroundStyle(HubStyle.folder).padding(size * 0.07)
                    if let symbol = folderSymbol {
                        Image(systemName: symbol).font(.system(size: size * 0.18, weight: .regular))
                            .foregroundStyle(HubStyle.onFolder).offset(y: size * 0.06)
                    }
                }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)).resizable().interpolation(.high)
            }
        }.frame(width: size, height: size)
    }
    private var folderSymbol: String? {
        switch file.name.lowercased() {
        case "dcim": return "camera.fill"
        case "download", "downloads": return "arrow.down"
        case "pictures": return "photo"
        case "movies": return "film"
        case "music": return "music.note"
        case "documents": return "doc.text"
        default: return nil
        }
    }
}

struct LibraryStateView<Actions: View>: View {
    let symbol: String?
    let title: String
    var detail = ""
    var isError = false
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 24))
                        .foregroundStyle(isError ? HubStyle.error : HubStyle.muted)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 52, height: 52)
            .background(isError ? HubStyle.errorSurface : HubStyle.well, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(HubStyle.ink)
                if !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(HubStyle.muted)
                        .lineSpacing(3).textSelection(.enabled)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            actions()
        }
        .padding(HubStyle.workspaceInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkspaceNotice: View {
    let message: String
    var isError = false
    var loading = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if loading {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            } else {
                Image(systemName: isError ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(isError ? HubStyle.error : HubStyle.accent)
                    .accessibilityHidden(true)
            }
            Text(message)
                .foregroundStyle(HubStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isError ? HubStyle.errorSurface : HubStyle.well, in: RoundedRectangle(cornerRadius: 8))
    }
}

func openToolSettings() {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}
