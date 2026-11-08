import SwiftUI
import UIKit

struct GameListRow: View {
    @Environment(\.dukeXTheme) private var theme

    let game: LibraryFile
    let metadata: GameListMetadata?
    let recentlyPlayedTime: TimeInterval
    let isLandscape: Bool
    let canLaunch: Bool
    let liveStatus: GameLiveStatus?
    let isFavorite: Bool
    let resolutionScale: Int
    let skipBoot: Bool
    let launch: () -> Void
    let addCover: () -> Void
    let copyLaunchLink: () -> Void
    let importConfig: () -> Void
    let setResolutionScale: (Int) -> Void
    let setSkipBoot: (Bool) -> Void
    let clearShaderCache: () -> Void
    let editGameData: () -> Void
    let toggleFavorite: () -> Void
    let requestRemoveGame: () -> Void

    @State private var descriptionExpanded = false

    var body: some View {
        listRow
        .opacity(canLaunch ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard canLaunch else {
                return
            }
            launch()
        }
        .contextMenu {
            menuItems
        }
    }

    private var listRow: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    framedCover(width: 58, height: 82, cornerRadius: 8)

                    metadataBlock

                    Spacer(minLength: 0)
                }

                if descriptionExpanded {
                    descriptionBlock
                        .padding(.top, 2)
                }

                if hasDescription {
                    expandButton
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, descriptionExpanded ? 0 : -2)
                }
            }
            .padding(12)

            if let liveStatus {
                LiveStatusBadge(status: liveStatus)
                    .padding(12)
            }
        }
        .background(rowBackground)
    }

    private func framedCover(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
        cover
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    private var metadataBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            if let rating = metadata?.esrbRating, rating != .none {
                ESRBRatingBadge(rating: rating)
                    .frame(width: 42, height: 58)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(Self.metadataFont.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(titleUsesTwoLines ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, liveStatus == nil ? 0 : 76)

                if !titleUsesTwoLines, let secondaryMetadataLine {
                    Text(secondaryMetadataLine)
                        .font(secondaryMetadataLineIsSubtitle ? Self.metadataFont.weight(.semibold) : Self.metadataFont)
                        .foregroundStyle(secondaryMetadataLineIsSubtitle ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.trailing, liveStatus == nil ? 0 : 76)
                }

                Text(metadata?.studioYearLine ?? "Game data not set")
                    .font(Self.metadataFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(lastPlayedText)
                    .font(Self.metadataFont.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var descriptionBlock: some View {
        JustifiedDescriptionText(
            text: descriptionText,
            font: .systemFont(ofSize: 11, weight: .regular),
            textColor: UIColor.label.withAlphaComponent(0.82),
            lineLimit: 0
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expandButton: some View {
        Button {
            descriptionExpanded.toggle()
        } label: {
            Image(systemName: descriptionExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(descriptionExpanded ? "Collapse game description" : "Expand game description")
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(theme.surfaceColor)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.borderColor, lineWidth: 1)
        }
    }

    private var descriptionText: String {
        metadata?.description.nilIfEmpty ?? "No game data has been added for this title."
    }

    private var hasDescription: Bool {
        metadata?.description.nilIfEmpty != nil
    }

    private var displayTitle: String {
        metadata?.title.nilIfEmpty ?? game.displayName
    }

    private var titleUsesTwoLines: Bool {
        displayTitle.count > (isLandscape ? 48 : (liveStatus == nil ? 24 : 18))
    }

    private var secondaryMetadataLine: String? {
        metadata?.subtitle.nilIfEmpty ?? normalizedTitleID
    }

    private var secondaryMetadataLineIsSubtitle: Bool {
        metadata?.subtitle.nilIfEmpty != nil
    }

    private var normalizedTitleID: String? {
        game.titleID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private var lastPlayedText: String {
        guard recentlyPlayedTime > 0 else {
            return "Last Played: Never"
        }
        return "Last Played: \(Self.lastPlayedFormatter.string(from: Date(timeIntervalSince1970: recentlyPlayedTime)))"
    }

    @ViewBuilder
    private var cover: some View {
        if let coverURL = game.coverURL,
           let image = UIImage(contentsOfFile: coverURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))

                Image(systemName: "opticaldisc")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: addCover) {
            Label("Add Cover", systemImage: "photo")
        }

        Button(action: copyLaunchLink) {
            Label("Copy Launch Link", systemImage: "link")
        }
        .disabled(GameLaunchLink.url(for: game) == nil)

        Button(action: importConfig) {
            Label(game.customConfigURL == nil ? "Import Config" : "Replace Config",
                  systemImage: "gearshape")
        }

        Menu {
            ForEach(GameResolutionScaleConfig.allowedValues, id: \.self) { scale in
                Button {
                    setResolutionScale(scale)
                } label: {
                    if resolutionScale == scale {
                        Label(GameResolutionScaleConfig.title(for: scale), systemImage: "checkmark")
                    } else {
                        Text(GameResolutionScaleConfig.title(for: scale))
                    }
                }
                .disabled(resolutionScale == scale)
            }
        } label: {
            Label("Display Quality (\(GameResolutionScaleConfig.title(for: resolutionScale)))", systemImage: "display")
        }

        Menu {
            ForEach([false, true], id: \.self) { enabled in
                Button {
                    setSkipBoot(enabled)
                } label: {
                    if skipBoot == enabled {
                        Label(enabled ? "On" : "Off", systemImage: "checkmark")
                    } else {
                        Text(enabled ? "On" : "Off")
                    }
                }
                .disabled(skipBoot == enabled)
            }
        } label: {
            Label("Skip Boot (\(skipBoot ? "On" : "Off"))", systemImage: "forward.end")
        }

        Button(action: clearShaderCache) {
            Label("Clear Shader Cache", systemImage: "xmark.bin")
        }

        Button(action: editGameData) {
            Label("Add Game Data", systemImage: "square.and.pencil")
        }

        Button(action: toggleFavorite) {
            Label(
                isFavorite ? "Remove Favorite" : "Add to Favorites",
                systemImage: isFavorite ? "star.slash" : "star"
            )
        }

        Button(role: .destructive, action: requestRemoveGame) {
            Label("Remove Game", systemImage: "trash")
        }
    }
}

private extension GameListRow {
    static let metadataFont = Font.system(size: 11)

    static let lastPlayedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter
    }()
}

private struct ESRBRatingBadge: View {
    let rating: ESRBRating

    var body: some View {
        if let assetName = rating.assetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("ESRB \(rating.title)")
        }
    }
}

private struct JustifiedDescriptionText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let textColor: UIColor
    let lineLimit: Int

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.backgroundColor = .clear
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.numberOfLines = lineLimit
        label.attributedText = attributedText
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UILabel,
                      context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private var attributedText: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .justified
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byTruncatingTail

        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
