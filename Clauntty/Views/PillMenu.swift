import SwiftUI
import UIKit

/// What a window's pill opens: an icon row of actions (a Claude pane's Chat | Terminal
/// first), then the workspace's panes, one section per tab (its web tabs last)
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
        /// An action with children is a native menu of them (`+`: what's new)
        var children: [Item] = []
        var perform: () -> Void = {}
    }

    /// A Claude pane shown as its chat or its terminal
    struct ViewSwitch {
        let isChat: Bool
        /// Not while Claude is in a turn or waiting on the user
        let isEnabled: Bool
        let choose: (_ chat: Bool) -> Void
    }

    /// Under the pill: a page's address, or why the view can't switch yet
    var caption: String? = nil
    var viewSwitch: ViewSwitch? = nil
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
    /// A hold opens it (an overview card's opens under the card instead)
    var holds = true
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

    static var space: String { menuSpace }
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
            .gesture(hold, including: holds ? .all : .subviews)
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
        MenuItems(menu: menu, lead: lead, room: room - pill.height, highlighted: highlighted, onChoose: choose)
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

/// An overview card held: it lifts, everything else dims, and its menu opens under it (over
/// it, near the bottom), as an app icon's on the home screen
struct CardMenuHost: ViewModifier {
    let isOn: Bool
    let menu: WindowMenu?
    let width: CGFloat
    let height: CGFloat
    /// How far the menu can reach down from the card's bottom, and up from its top
    let room: CGFloat
    let above: CGFloat
    let onClose: () -> Void

    private static let gap: CGFloat = 8

    func body(content: Content) -> some View {
        let menuHeight = menu.map(MenuItems.height) ?? 0
        let below = menuHeight + Self.gap <= room || room >= above
        let maxHeight = (below ? room : above) - Self.gap
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        content
            .scaleEffect(isOn ? 1.02 : 1)
            .shadow(color: .black.opacity(isOn ? 0.35 : 0), radius: 14, y: 6)
            .background {
                if isOn {
                    // Everything else, dimmed; a tap there closes
                    Color.black.opacity(0.3)
                        .frame(width: 4000, height: 4000)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onClose)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if isOn, let menu {
                    // The pill's menu without the pill: the card shows what it would
                    MenuItems(menu: menu, lead: 8, room: maxHeight) { item in
                        onClose()
                        item.perform()
                    }
                    .padding(.top, 4)
                    .frame(width: min(width, 330))
                    .clipShape(shape)
                    .glass(in: shape)
                    // Under the card, or over it: its rows are a fixed height
                        .offset(y: below ? height + Self.gap : -(min(menuHeight + 4, maxHeight) + Self.gap))
                        .transition(.scale(scale: 0.6, anchor: below ? .topLeading : .bottomLeading)
                            .combined(with: .opacity))
                }
            }
    }
}

/// Where a menu's rows are, for a holding finger to find
private let menuSpace = "pillMenu"

/// A window's menu, below the pill or a card: an icon row of its actions, then its panes'
/// rows, scrolling past `room`
struct MenuItems: View {
    let menu: WindowMenu
    /// How far in the rows' icons are from the panel's edge: under the pill's glyph
    let lead: CGFloat
    /// How tall it can be
    let room: CGFloat
    /// The row under a holding finger
    var highlighted: String? = nil
    let onChoose: (WindowMenu.Item) -> Void

    static let rowHeight: CGFloat = 44
    private static let actionsHeight: CGFloat = 50
    private static let captionHeight: CGFloat = 22
    private static let sectionGap: CGFloat = 9
    private static let bottomPad: CGFloat = 10

    /// Its height, all its rows showing
    static func height(_ menu: WindowMenu) -> CGFloat {
        fixedHeight(menu) + rowsHeight(menu)
    }

    private static func fixedHeight(_ menu: WindowMenu) -> CGFloat {
        (menu.caption == nil ? 0 : captionHeight) + actionsHeight + 4 + (menu.sections.isEmpty ? 0 : 8) + bottomPad
    }

    private static func rowsHeight(_ menu: WindowMenu) -> CGFloat {
        CGFloat(menu.sections.reduce(0) { $0 + $1.count }) * rowHeight
            + CGFloat(max(0, menu.sections.count - 1)) * sectionGap
    }

    var body: some View {
        let rowsRoom = room - Self.fixedHeight(menu)
        VStack(alignment: .leading, spacing: 0) {
            if let caption = menu.caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, lead + 12)
                    .padding(.trailing, 20)
                    .frame(height: Self.captionHeight)
            }
            // The actions, then Close apart at the end. A page's actions (no Close) spread
            // over the row.
            HStack(spacing: 0) {
                if let view = menu.viewSwitch {
                    ChatTerminalToggle(view: view) { chat in
                        onChoose(.init(id: "view", title: chat ? "Chat" : "Terminal", icon: "") { view.choose(chat) })
                    }
                    .padding(.leading, 2)
                    .padding(.trailing, 6)
                }
                let spread = menu.viewSwitch == nil && !menu.actions.contains { $0.isDestructive }
                ForEach(menu.actions.filter { !$0.isDestructive }) { item in
                    if spread {
                        actionButton(item).frame(maxWidth: .infinity)
                    } else {
                        actionButton(item, circled: true).padding(.trailing, 6)
                    }
                }
                if !spread { Spacer(minLength: 0) }
                ForEach(menu.actions.filter(\.isDestructive)) { item in
                    actionButton(item, circled: true).padding(.trailing, 8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .frame(height: Self.actionsHeight + 4)
            if !menu.sections.isEmpty {
                separator.padding(.top, 4)
                if Self.rowsHeight(menu) <= rowsRoom {
                    sections.padding(.top, 4)
                } else {
                    ScrollView { sections.padding(.top, 4) }
                        // At least a row (landscape above the keyboard has room for
                        // about that)
                        .frame(height: max(Self.rowHeight, rowsRoom))
                }
            }
        }
        .padding(.bottom, Self.bottomPad)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
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
            .fill(Color.primary.opacity(0.12))
            .frame(height: 0.5)
            .padding(.horizontal, 20)
    }

    /// An icon, or (`circled`, beside Chat | Terminal and Close) an icon on a circle the
    /// toggle's height, in its fill and edge
    @ViewBuilder
    private func actionIcon(_ item: WindowMenu.Item, circled: Bool) -> some View {
        let icon = Image(systemName: item.icon)
            .foregroundStyle(item.isDestructive ? Color.red : Color.primary)
        if circled {
            icon
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                .frame(minHeight: Self.actionsHeight - 8)
                .contentShape(Circle())
        } else {
            icon
                .font(.system(size: 19, weight: .regular))
                .frame(maxWidth: .infinity, minHeight: Self.actionsHeight - 8)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func actionButton(_ item: WindowMenu.Item, circled: Bool = false) -> some View {
        if !item.children.isEmpty, circled, #available(iOS 26.0, *) {
            // A system glass button: its menu grows out of it (Liquid Glass's morph)
            Menu {
                ForEach(item.children) { child in
                    Button { onChoose(child) } label: { SwiftUI.Label(child.title, systemImage: child.icon) }
                        .disabled(child.isDisabled)
                }
            } label: {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .menuOrder(.fixed)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .frame(minHeight: Self.actionsHeight - 8)
            .accessibilityLabel(item.title)
        } else if !item.children.isEmpty {
            Menu {
                ForEach(item.children) { child in
                    Button { onChoose(child) } label: { SwiftUI.Label(child.title, systemImage: child.icon) }
                        .disabled(child.isDisabled)
                }
            } label: {
                actionIcon(item, circled: circled)
            }
            .menuOrder(.fixed)
            .accessibilityLabel(item.title)
        } else {
            plainActionButton(item, circled: circled)
        }
    }

    @ViewBuilder
    private func plainActionButton(_ item: WindowMenu.Item, circled: Bool) -> some View {
        if circled, #available(iOS 26.0, *) {
            // A system glass button, as + is
            Button { onChoose(item) } label: {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(item.isDestructive ? Color.red : Color.primary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .frame(minHeight: Self.actionsHeight - 8)
            .disabled(item.isDisabled)
            .opacity(item.isDisabled ? 0.35 : 1)
            .accessibilityLabel(item.title)
            .background(frameReader(item))
        } else {
            flatActionButton(item, circled: circled)
        }
    }

    private func flatActionButton(_ item: WindowMenu.Item, circled: Bool) -> some View {
        Button { onChoose(item) } label: {
            actionIcon(item, circled: circled)
        }
        .buttonStyle(MenuRowStyle(highlighted: highlighted == item.id, cornerRadius: circled ? 18 : 14))
        .disabled(item.isDisabled)
        .opacity(item.isDisabled ? 0.35 : 1)
        .accessibilityLabel(item.title)
        .background(frameReader(item))
    }

    /// A row's icon in the pill's glyph column: `lead` in from the panel's edge, as the
    /// pill is
    private func row(_ item: WindowMenu.Item) -> some View {
        Button { onChoose(item) } label: {
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
                                   value: item.isDisabled ? [:] : [item.id: g.frame(in: .named(menuSpace))])
        }
    }
}

/// Chat | Terminal: two words on a dark capsule, the one showing on a darker one inside it
/// that slides across when the other is picked
private struct ChatTerminalToggle: View {
    let view: WindowMenu.ViewSwitch
    let choose: (_ chat: Bool) -> Void
    @State private var picked: Bool?
    @Namespace private var thumb

    var body: some View {
        let isChat = picked ?? view.isChat
        HStack(spacing: 0) {
            option("Chat", on: isChat) { pick(true) }
            option("Terminal", on: !isChat) { pick(false) }
        }
        .padding(3)
        .modifier(ToggleTrack())
        .opacity(view.isEnabled ? 1 : 0.4)
        .allowsHitTesting(view.isEnabled)
    }

    private func option(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(on ? 1 : 0.7))
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background {
                    if on {
                        Capsule()
                            .fill(Color.black.opacity(0.55))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The thumb slides over first; then the menu closes and the pane switches
    private func pick(_ chat: Bool) {
        guard chat != (picked ?? view.isChat) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { picked = chat }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { choose(chat) }
    }
}

/// The toggle's capsule: glass, as the glass buttons beside it, where the system has it
private struct ToggleTrack: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
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
                    .fill(Color.primary.opacity(highlighted || configuration.isPressed ? 0.14 : 0))
            )
    }
}
