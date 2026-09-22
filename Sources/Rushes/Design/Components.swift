import AppKit
import SwiftUI

/// Numbers and sizes the French way: "64,2 Go", "1 243 photos".
enum Format {
    static func bytes(_ count: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: max(count, 0))
    }

    static func number(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "fr_FR")))
    }

    /// "1 fichier", "12 fichiers". Nouns whose plural is not an s pass it.
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number(n)) \(n > 1 ? (plural ?? singular + "s") : singular)"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) s" }
        if s < 3600 { return "\(s / 60) min \(String(format: "%02d", s % 60)) s" }
        return "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60))"
    }

    static func day(_ day: ShootDay) -> String {
        day.date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).weekday(.wide).day().month(.wide))
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour().minute())
    }

    /// "Lundi 21 septembre", as a page's trail says it.
    static func sentenceDay(_ date: Date) -> String {
        let text = date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).weekday(.wide).day().month(.wide))
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: - The page, Cairn's frame

/// One column, one gutter, one top margin, one ground, as in Cairn.
enum Page {
    static let width: CGFloat = 900
    static let gutter: CGFloat = 44
    static let top: CGFloat = 30
    static let washHeight: CGFloat = 240
}

/// A page that scrolls, its column placed from the window's edge rather than
/// centred in the scroll view, so a scroller that takes room does not move the
/// title by half its width.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var outer: CGFloat = Page.width

    var body: some View {
        ScrollView {
            content
                .frame(width: max(0, min(Page.width, outer) - Page.gutter * 2), alignment: .leading)
                .padding(.leading, max(0, (outer - Page.width) / 2) + Page.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { outer = $0 }
    }
}

extension View {
    /// Every page sits on the ground, the forest washing down from the top.
    func pageGround() -> some View {
        background(Palette.ground)
            .background(alignment: .top) {
                LinearGradient(colors: Palette.wash, startPoint: .top, endPoint: .bottom)
                    .frame(height: Page.washHeight)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
    }
}

/// The line above a page's title, which says where the backup stands.
struct PageTrail: View {
    let steps: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.inkFaint)
                }
                Text(step).foregroundStyle(index == steps.count - 1 ? Palette.inkFaint : Palette.inkSoft)
            }
        }
        .font(TypeScale.meta)
        .lineLimit(1)
        .frame(height: 16, alignment: .leading)
    }
}

/// The one level of heading inside a block: the section's name in the label
/// size, its count if it has one, and on the right whatever acts on it, as
/// accent links.
struct SectionHeader<Actions: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(TypeScale.label)
                .foregroundStyle(Palette.inkSoft)
            if let count, count > 0 {
                Text("\(count)")
                    .font(TypeScale.numbers)
                    .foregroundStyle(Palette.inkFaint)
            }
            Spacer(minLength: 8)
            actions
                .buttonStyle(.accentLink)
                .font(TypeScale.meta)
        }
    }
}

extension SectionHeader where Actions == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// A group inside a block.
struct GroupLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TypeScale.group)
            .foregroundStyle(Palette.inkFaint)
    }
}

/// A group that belongs together on a page: the paler ivory, a hairline, the
/// surface radius. Cairn's `Block`.
struct Block<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// A section of a page, flat on the ground: a hairline above, its name in
/// serif in a column of its own, what it holds in sans beside it. The page
/// reads as one sheet rather than a pile of cards; `stacked` puts the name
/// above instead, for a narrow window or a section that needs the width.
struct PageSection<Content: View>: View {
    let title: String
    var stacked = false
    @ViewBuilder var content: Content

    static var titleWidth: CGFloat { 150 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 14) {
                        heading
                        content.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        heading.frame(width: Self.titleWidth, alignment: .leading)
                        content.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 24)
        }
    }

    private var heading: some View {
        Text(title)
            .font(TypeScale.strong)
            .foregroundStyle(Palette.ink)
    }
}

/// A label above a field, and a line of help under it if it needs one.
/// Cairn's sheet field: the ground inside, a hairline, the control radius.
struct Field<Content: View>: View {
    let label: String
    var help: String?
    var monospaced = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(TypeScale.label)
                .foregroundStyle(Palette.inkSoft)
            content
                .inputChrome(monospaced: monospaced)
            if let help {
                Text(help)
                    .font(TypeScale.meta)
                    .foregroundStyle(Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// The look of every field: the paler ivory on the ground, a hairline around.
    func inputChrome(monospaced: Bool = false) -> some View {
        textFieldStyle(.plain)
            .font(monospaced ? TypeScale.code : TypeScale.ui)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline))
    }
}

// MARK: - Buttons, Cairn's

/// A text button in the accent. The system link style paints in link blue.
struct AccentLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentLinkLabel(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct AccentLinkLabel<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .foregroundStyle(isEnabled ? Palette.accentInk : Palette.inkFaint)
            .opacity(isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// The one button that says "this is the way on": a capsule of pastel sage,
/// labelled in `onAccent`, a hairline of `accentLine` to hold its shape.
struct AccentFilledStyle: ButtonStyle {
    var color: Color?

    func makeBody(configuration: Configuration) -> some View {
        AccentFilledLabel(label: configuration.label, isPressed: configuration.isPressed, color: color)
    }
}

private struct AccentFilledLabel<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let color: Color?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        label
            .font(controlSize == .extraLarge ? .system(size: 15, weight: .semibold) : TypeScale.ui.weight(.medium))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, controlSize == .extraLarge ? 22 : controlSize == .large ? 16 : 12)
            .frame(minHeight: height)
            .background(Capsule().fill(color ?? Palette.accent))
            .overlay(Capsule().strokeBorder(Palette.accentLine.opacity(0.45), lineWidth: 1))
            .brightness(isPressed ? -0.05 : 0)
            .scaleEffect(isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }

    private var height: CGFloat {
        switch controlSize {
        case .mini: 16
        case .small: 20
        case .large: 30
        case .extraLarge: 38
        default: 24
        }
    }
}

extension ButtonStyle where Self == AccentLinkStyle {
    static var accentLink: AccentLinkStyle { AccentLinkStyle() }
}

extension ButtonStyle where Self == AccentFilledStyle {
    static var accentFilled: AccentFilledStyle { AccentFilledStyle() }
}

/// A checkbox drawn in the accent. The system one is blue and sits badly
/// beside serif text.
struct ForestCheckbox: View {
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(checked ? Palette.accentLine : Palette.hairlineStrong, lineWidth: 1.2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(checked ? Palette.accent : .clear))
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.onAccent)
                }
            }
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(checked ? "Incluse" : "Laissée de côté")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// A preset or a filter: a capsule, pastel sage when chosen, and a count in
/// numerals after the words when it has one.
struct Chip: View {
    let text: String
    var count: Int?
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text)
                    .font(TypeScale.meta)
                if let count {
                    Text(Format.number(count))
                        .font(TypeScale.numbers)
                        .opacity(0.7)
                }
            }
            .foregroundStyle(selected ? Palette.onAccent : Palette.inkSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Palette.accent : .clear))
            .overlay(Capsule().strokeBorder(selected ? .clear : Palette.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A camera letter in its pastel, as Cairn marks a project.
struct CameraBadge: View {
    let label: String

    var body: some View {
        Text(label.isEmpty ? "?" : label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Palette.onCamera(label))
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, label.count > 1 ? 4 : 0)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.camera(label)))
    }
}

/// The camera letter, typed where it shows: click, type D, done.
struct CameraLetterField: View {
    let label: String
    let onChange: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            // A grouped Form lays a field out as a labelled row and pushes its
            // text down; without a label it keeps to the badge. VoiceOver still
            // needs one, and a lone letter says nothing on its own.
            .labelsHidden()
            .accessibilityLabel("Lettre de la caméra")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center)
            .foregroundStyle(focused ? Palette.ink : Palette.onCamera(text))
            .frame(width: max(24, CGFloat(text.count) * 9 + 14), height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(focused ? Palette.ground : Palette.camera(text))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Palette.accentLine : .clear, lineWidth: 1.5)
            )
            .focused($focused)
            .onAppear { text = label }
            .onChange(of: label) { _, new in if !focused { text = new } }
            .onChange(of: text) { _, new in
                let clean = String(Sanitize.code(new).prefix(3))
                if clean != new { text = clean }
                if !clean.isEmpty, clean != label { onChange(clean) }
            }
            .onChange(of: focused) { _, now in if !now, text.isEmpty { text = label } }
            .onSubmit { focused = false }
    }
}

/// The bar of a backup, and a drive's space.
struct Bar: View {
    let fraction: Double
    var height: CGFloat = 6
    var fill: Color = Palette.accentLine
    var extra: Double = 0
    var extraFill: Color = Palette.accentSoft

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                Capsule().fill(extraFill)
                    .frame(width: geo.size.width * min(max(fraction + extra, 0), 1))
                Capsule().fill(fill)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// Lays its children out in lines, wrapping when the width runs out.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
