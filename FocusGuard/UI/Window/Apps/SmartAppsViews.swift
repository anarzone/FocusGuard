import SwiftUI

// Smart categories (Pro) in Apps & Sites: the banner over the list, the
// reason lines, and youtube.com's video-by-video section.

/// "Sorted 19 of 21 new apps and sites · 2 need you", over the Used list.
struct SmartBannerBar: View {
    let banner: SmartBanner
    let onReview: () -> Void
    let onClose: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            Text(banner.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text("Worked out on this Mac")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            if banner.needYou > 0 {
                Button("Review", action: onReview)
                    .buttonStyle(.capsule(.secondary, height: 26))
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(shape.fill(Theme.focus.opacity(0.08)))
        .overlay(shape.strokeBorder(Theme.focus.opacity(0.22), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

/// In place of the category control while youtube.com is judged per video.
struct PerVideoPill: View {
    var height: CGFloat = 26

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.focus)
            Text("Decided per video").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primaryText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.focus.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

/// A sparkle, a bold lead and smart categories' reason.
struct SmartReasonLine: View {
    let lead: String
    let reason: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            (Text(lead + " ").fontWeight(.semibold) + Text(reason))
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// youtube.com in the inspector: video by video on or off (Pro), and the
/// recent videos with their verdicts, each one correctable.
struct YouTubePerVideoSection: View {
    @Bindable var appState: AppState
    let item: AppsItem
    let onChange: () -> Void
    var entitlements: Entitlements = .shared

    @Environment(\.openWindowSheet) private var openSheet

    private var smart: SmartCategories { appState.smartCategories }

    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5)
        if entitlements.isUnlocked(.youtubePerVideo) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Decide video by video").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.primaryText)
                            ProBadge()
                        }
                        Text(smart.isModelAvailable || smart.perVideo
                             ? "Each video's title is compared with what you're working on, on this Mac. Talks and tutorials count as focus, the rest as distracting."
                             : OnDeviceAI.unavailableNote)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("Decide video by video", isOn: Binding(get: { smart.perVideo },
                                                                  set: { smart.setPerVideo($0); onChange() }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!smart.isModelAvailable && !smart.perVideo)
                }
                if smart.perVideo {
                    recentVideos
                }
            }
        } else {
            LockedProRow(feature: .youtubePerVideo, title: "Decide video by video",
                         detail: "Each video judged by its title on this Mac: talks and tutorials count as focus, the rest as distracting.",
                         systemImage: "play.rectangle",
                         onTrialStarted: { smart.setPerVideo(true); onChange() },
                         onUpgrade: { openSheet(.upgrade(.youtubePerVideo)) })
        }
    }

    @ViewBuilder private var recentVideos: some View {
        let videos = smart.recentVideos(limit: 5)
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent videos").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
            if videos.isEmpty {
                Text("Videos you watch show up here with how they counted.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(videos) { video in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(video.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                                .lineLimit(1).truncationMode(.tail)
                            Text(video.byUser ? "\(video.kind) · you corrected it" : video.kind)
                                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(video.title)
                        CategoryChipMenu(current: video.classification) { c in
                            smart.correct(video.videoId, as: c)
                            onChange()
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                Text("Wrong call? Click a label to correct it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}
