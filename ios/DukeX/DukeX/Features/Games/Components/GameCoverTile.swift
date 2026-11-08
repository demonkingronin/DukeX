import SwiftUI
import UIKit

enum GameCoverTilePresentation {
    case standard
    case controllerLandscapePage

    var outerPadding: CGFloat {
        switch self {
        case .standard:
            return 10
        case .controllerLandscapePage:
            return 8
        }
    }

    var verticalSpacing: CGFloat {
        switch self {
        case .standard:
            return 6
        case .controllerLandscapePage:
            return 5
        }
    }

    var titleFontSize: CGFloat {
        switch self {
        case .standard:
            return 11
        case .controllerLandscapePage:
            return 10
        }
    }

    var titleHeight: CGFloat {
        switch self {
        case .standard:
            return 28
        case .controllerLandscapePage:
            return 24
        }
    }

    var tileCornerRadius: CGFloat {
        switch self {
        case .standard:
            return 16
        case .controllerLandscapePage:
            return 14
        }
    }

    var coverCornerRadius: CGFloat {
        switch self {
        case .standard:
            return 10
        case .controllerLandscapePage:
            return 9
        }
    }

    var liveStatusPadding: CGFloat {
        switch self {
        case .standard:
            return 7
        case .controllerLandscapePage:
            return 6
        }
    }
}

struct GameCoverTile: View {
    @Environment(\.dukeXTheme) private var theme

    private static let coverAspectRatio: CGFloat = 0.70

    let game: LibraryFile
    let canLaunch: Bool
    let liveStatus: GameLiveStatus?
    let isFavorite: Bool
    let resolutionScale: Int
    var isHighlighted = false
    var presentation: GameCoverTilePresentation = .standard
    let launch: () -> Void
    let addCover: () -> Void
    let copyLaunchLink: () -> Void
    let importConfig: () -> Void
    let setResolutionScale: (Int) -> Void
    let clearShaderCache: () -> Void
    let toggleFavorite: () -> Void
    let requestRemoveGame: () -> Void

    var body: some View {
        VStack(spacing: presentation.verticalSpacing) {
            Button(action: launch) {
                coverWithLiveStatus
            }
            .buttonStyle(.plain)
            .disabled(!canLaunch)

            Button(action: launch) {
                Text(game.displayName)
                    .font(.system(size: presentation.titleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .lineSpacing(0)
                    .frame(maxWidth: .infinity,
                           minHeight: presentation.titleHeight,
                           maxHeight: presentation.titleHeight,
                           alignment: .top)
                    .clipped()
            }
            .buttonStyle(.plain)
            .disabled(!canLaunch)
        }
        .padding(presentation.outerPadding)
        .frame(maxWidth: .infinity)
        .background(theme.surfaceColor,
                    in: RoundedRectangle(cornerRadius: presentation.tileCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: presentation.tileCornerRadius, style: .continuous)
                .strokeBorder(isHighlighted ? Color.accentColor : theme.borderColor,
                              lineWidth: isHighlighted ? 2 : 1)
        }
        .contentShape(Rectangle())
        .opacity(canLaunch ? 1 : 0.55)
        .shadow(color: isHighlighted ? Color.accentColor.opacity(0.35) : .clear,
                radius: isHighlighted ? 10 : 0,
                x: 0,
                y: 0)
        .scaleEffect(isHighlighted ? 1.025 : 1)
        .animation(.easeInOut(duration: 0.14), value: isHighlighted)
        .contextMenu {
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
                            Label("\(scale)×", systemImage: "checkmark")
                        } else {
                            Text("\(scale)×")
                        }
                    }
                    .disabled(resolutionScale == scale)
                }
            } label: {
                Label("Display Quality (\(resolutionScale)×)", systemImage: "display")
            }

            Button(action: clearShaderCache) {
                Label("Clear Shader Cache", systemImage: "xmark.bin")
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

    @ViewBuilder
    private var coverWithLiveStatus: some View {
        Color.clear
            .aspectRatio(Self.coverAspectRatio, contentMode: .fit)
            .overlay {
                ZStack(alignment: .topTrailing) {
                    cover
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    if let liveStatus {
                        LiveStatusBadge(status: liveStatus)
                            .padding(presentation.liveStatusPadding)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: presentation.coverCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: presentation.coverCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
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

                VStack(spacing: 10) {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 42, weight: .regular))
                    Text(game.fallbackDisplayName)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 10)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
