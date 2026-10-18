import SwiftUI
import UIKit

/// What a window's pill opens: an icon row of actions, then the workspace's panes, one
/// section per tab (its web tabs last)
struct WindowMenu {
    struct Item: Identifiable {
        let id: String
        let title: String
        var subtitle: String? = nil
        let icon: String
        var tint: Color? = nil
        var isOn = false
        var isDestructive = false
        var isDisabled = false
        let perform: () -> Void
    }

    /// Under the pill: a page's address
    var caption: String? = nil
    let actions: [Item]
    var sections: [[Item]] = []
}

/// A window's pill that grows into its menu. The pill stays where it is, title and all;
/// its glass opens down from it over the window. Tap to open (where `tapOpens`), or hold
/// it, slide to a row and let go.
struct PillMenu<Label: View>: View {
    let isOpen: Bool
    /// Built while open
    let menu: WindowMenu?
    /// A tap opens it (typed into, or fullscreen); otherwise a tap is `onTap`
    let tapOpens: Bool
    /// The open panel's width at most
    let maxWidth: CGFloat
    /// How far the panel can reach down from the pill's top
    let room: CGFloat
    let onOpen: () -> Void
    let onClose: () -> Void
    let onTap: () -> Void
    /// The pill, without glass: the menu draws it
    @ViewBuilder let label: () -> Label

    /// The row under the finger while holding
    @State private var highlighted: String?
    @State private var rowFrames: [String: CGRect] = [:]

    static var space: String { "pillMenu" }
    private static var rowHeight: CGFloat { 44 }
    private static var actionsHeight: CGFloat { 50 }

    var body: some View {
        label()
            .contentShape(Capsule())
            .onTapGesture {
                if isOpen { onClose() } else if tapOpens { onOpen() } else { onTap() }
            }
            .gesture(hold)
            .background(alignment: .topLeading) {
                // The pill's glass, which is the panel's: one shape that grows
                GeometryReader { g in
                    panel(pill: g.size)
                }
            }
            .background {
                if isOpen {
                    // Everything else, dimmed; a tap there closes
                    Color.black.opacity(0.3)
                        .frame(width: 4000, height: 4000)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onClose)
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
    }

    private func panel(pill: CGSize) -> some View {
        let width = max(pill.width, min(maxWidth, 320))
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: pill.height)
            if isOpen, let menu {
                content(menu, pill: pill)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(width: isOpen ? width : pill.width, alignment: .topLeading)
        // The rows stay inside the glass as it grows
        .clipShape(RoundedRectangle(cornerRadius: isOpen ? 24 : pill.height / 2, style: .continuous))
        .glass(in: RoundedRectangle(cornerRadius: isOpen ? 24 : pill.height / 2, style: .continuous))
    }

    private func content(_ menu: WindowMenu, pill: CGSize) -> some View {
        let rows = CGFloat(menu.sections.reduce(0) { $0 + $1.count }) * Self.rowHeight
            + CGFloat(max(0, menu.sections.count - 1)) * 9
        let fixed = pill.height + (menu.caption == nil ? 0 : 22) + Self.actionsHeight + 16
        let fits = rows <= room - fixed
        return VStack(alignment: .leading, spacing: 0) {
            if let caption = menu.caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .frame(height: 22)
            }
            HStack(spacing: 0) {
                ForEach(menu.actions) { item in
                    actionButton(item)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Self.actionsHeight)
            if !menu.sections.isEmpty {
                separator
                if fits {
                    sections(menu.sections)
                } else {
                    ScrollView { sections(menu.sections) }
                        .frame(height: max(Self.rowHeight * 2, room - fixed))
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func sections(_ sections: [[WindowMenu.Item]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    separator.padding(.vertical, 4)
                }
                ForEach(section) { item in
                    row(item)
                }
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }

    private func actionButton(_ item: WindowMenu.Item) -> some View {
        Button { choose(item) } label: {
            Image(systemName: item.icon)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(item.isDestructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, minHeight: Self.actionsHeight - 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle(highlighted: highlighted == item.id, cornerRadius: 14))
        .disabled(item.isDisabled)
        .opacity(item.isDisabled ? 0.35 : 1)
        .accessibilityLabel(item.title)
        .background(frameReader(item))
    }

    private func row(_ item: WindowMenu.Item) -> some View {
        Button { choose(item) } label: {
            // The icons in the pill's glyph column, the current one checked at the end
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(item.tint ?? .secondary)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 16))
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if item.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(item.isDestructive ? Color.red : Color.primary)
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle(highlighted: highlighted == item.id, cornerRadius: 12))
        .padding(.horizontal, 6)
        .disabled(item.isDisabled)
        .opacity(item.isDisabled ? 0.35 : 1)
        .background(frameReader(item))
    }

    /// Where an enabled row is, for the finger to find
    private func frameReader(_ item: WindowMenu.Item) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: RowFrames.self,
                                   value: item.isDisabled ? [:] : [item.id: g.frame(in: .named(Self.space))])
        }
    }

    private func choose(_ item: WindowMenu.Item) {
        guard !item.isDisabled else { return }
        highlighted = nil
        onClose()
        item.perform()
    }

    /// Hold the pill: the menu opens, the finger slides to a row, letting go there picks
    /// it (anywhere else leaves the menu open)
    private var hold: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !isOpen {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onOpen()
                }
                guard let drag else { return }
                let id = rowFrames.first { $0.value.contains(drag.location) }?.key
                if id != highlighted {
                    if id != nil { UISelectionFeedbackGenerator().selectionChanged() }
                    highlighted = id
                }
            }
            .onEnded { value in
                defer { highlighted = nil }
                guard case .second(true, let drag?) = value,
                      let id = rowFrames.first(where: { $0.value.contains(drag.location) })?.key,
                      let item = menu.flatMap({ menu in (menu.actions + menu.sections.flatMap { $0 }).first { $0.id == id } })
                else { return }
                choose(item)
            }
    }
}

private struct RowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A row lit while pressed, or while the holding finger is over it
private struct MenuRowStyle: ButtonStyle {
    let highlighted: Bool
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(highlighted || configuration.isPressed ? 0.14 : 0))
            )
    }
}
