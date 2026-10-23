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
    /// The pill is at the right: the panel grows left from it
    var trailing = false
    /// Closed, it draws nothing (its label hides itself too): a card's, to hold
    var hidesClosed = false
    let onOpen: () -> Void
    let onClose: () -> Void
    let onTap: () -> Void
    /// The pill, without glass: the menu draws it
    @ViewBuilder let label: () -> Label

    /// The row under the finger while holding
    @State private var highlighted: String?
    /// When a hold opened it: letting go within a second or so ends as a tap too, which
    /// closed it mid-animation
    @State private var heldOpenAt = Date.distantPast
    @State private var rowFrames: [String: CGRect] = [:]

    static var space: String { "pillMenu" }
    private static var rowHeight: CGFloat { 44 }
    private static var actionsHeight: CGFloat { 50 }
    /// How far the open panel reaches past the pill, up and to the left: to the corner of
    /// the window around it
    private static var margin: CGFloat { 8 }

    var body: some View {
        label()
            .contentShape(Capsule())
            .onTapGesture {
                if isOpen {
                    // The tap that ends the hold that opened it
                    guard Date().timeIntervalSince(heldOpenAt) > 1 else { return }
                    onClose()
                } else if tapOpens {
                    onOpen()
                } else {
                    onTap()
                }
            }
            .gesture(hold)
            .background(alignment: .topLeading) {
                // The pill's glass, which is the panel's: one shape that grows
                GeometryReader { g in
                    // Short of the screen's edge
                    let frame = g.frame(in: .global)
                    let room = trailing ? UIScreen.main.bounds.width - frame.maxX : frame.minX
                    panel(pill: g.size, lead: min(Self.margin, max(0, room - 6)))
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

    /// Open, the panel's corner moves out past the pill's by `lead` (and the margin up),
    /// so the pill sits inside it with room around
    private func panel(pill: CGSize, lead: CGFloat) -> some View {
        let lead = isOpen ? lead : 0
        let lift = isOpen ? Self.margin : 0
        let width = max(pill.width + 2 * lead, min(maxWidth + lead, 330))
        let shape = RoundedRectangle(cornerRadius: isOpen ? 22 : pill.height / 2, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: pill.height + lift)
            if isOpen, let menu {
                content(menu, pill: pill, lead: lead)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(width: isOpen ? width : pill.width, alignment: .topLeading)
        // The rows stay inside the glass as it grows
        .clipShape(shape)
        .glass(in: shape)
        .opacity(hidesClosed && !isOpen ? 0 : 1)
        .offset(x: trailing && isOpen ? pill.width + lead - width : -lead, y: -lift)
    }

    private func content(_ menu: WindowMenu, pill: CGSize, lead: CGFloat) -> some View {
        let rows = CGFloat(menu.sections.reduce(0) { $0 + $1.count }) * Self.rowHeight
            + CGFloat(max(0, menu.sections.count - 1)) * 9
        let fixed = pill.height + (menu.caption == nil ? 0 : 22) + Self.actionsHeight + 22
        let fits = rows <= room - fixed
        return VStack(alignment: .leading, spacing: 0) {
            if let caption = menu.caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, lead + 12)
                    .padding(.trailing, 20)
                    .frame(height: 22)
            }
            HStack(spacing: 0) {
                ForEach(menu.actions) { item in
                    actionButton(item)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .frame(height: Self.actionsHeight + 4)
            if !menu.sections.isEmpty {
                separator.padding(.top, 4)
                if fits {
                    sections(menu.sections, lead: lead).padding(.top, 4)
                } else {
                    ScrollView { sections(menu.sections, lead: lead).padding(.top, 4) }
                        // At least a row (landscape above the keyboard has room for
                        // about that)
                        .frame(height: max(Self.rowHeight, room - fixed))
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func sections(_ sections: [[WindowMenu.Item]], lead: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    separator.padding(.vertical, 4)
                }
                ForEach(section) { item in
                    row(item, lead: lead)
                }
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 0.5)
            .padding(.horizontal, 20)
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

    /// A row's icon in the pill's glyph column: `lead` in from the panel's edge, as the
    /// pill is
    private func row(_ item: WindowMenu.Item, lead: CGFloat) -> some View {
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
            .padding(.leading, max(6, lead))
            .padding(.trailing, 12)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle(highlighted: highlighted == item.id, cornerRadius: 14))
        .padding(.horizontal, 8)
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
                    Haptic.lift.play()
                    heldOpenAt = Date()
                    onOpen()
                }
                guard let drag else { return }
                let id = rowFrames.first { $0.value.contains(drag.location) }?.key
                if id != highlighted {
                    if id != nil { Haptic.scrub.play() }
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
