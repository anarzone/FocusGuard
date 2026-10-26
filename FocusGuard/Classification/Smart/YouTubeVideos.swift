import Foundation

/// YouTube video by video (Pro): each watched video is judged by its
/// title. Talks and tutorials count as focus, the rest as distracting.
/// youtube.com's own category doesn't change.
enum YouTubeVideos {
    static let host = "youtube.com"

    /// The video id of a youtube.com/watch page, else nil.
    static func videoId(in url: String) -> String? {
        guard let components = URLComponents(string: url), let host = components.host,
              Classifier.host(host, matches: Self.host),
              components.path == "/watch",
              let id = components.queryItems?.first(where: { $0.name == "v" })?.value,
              !id.isEmpty, id.count <= 20 else { return nil }
        return id
    }

    /// The video's title from the tab's: no unread count, no " - YouTube".
    /// Nil for a page still loading ("YouTube").
    static func videoTitle(_ tabTitle: String?) -> String? {
        guard var title = tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let match = title.firstMatch(of: /^\(\d+\)\s*/) { title.removeSubrange(match.range) }
        for suffix in [" - YouTube", " – YouTube", " — YouTube"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != "YouTube" else { return nil }
        return title
    }

    /// Videos per question.
    static let batchSize = 5

    struct Pending: Equatable {
        let videoId: String
        let title: String
    }

    static let instructions = """
        You decide whether a YouTube video helps someone work or study, from its title.
        focus: talks, lectures, courses, tutorials, conference sessions and how-tos, \
        especially ones about what they're working on.
        distracting: everything else, like entertainment, sport, gaming, vlogs, news and music videos.
        Describe each video in two to five plain words, like "coding tutorial" or "race highlights".
        """

    private struct Answer: Decodable {
        struct Video: Decodable {
            let id: String
            let kind: String
            let category: String
        }
        let videos: [Video]
    }

    static func shape(ids: [String]) -> AnswerShape {
        .object([
            .init("videos", "One entry for each video, in the order given", .list(of: .object([
                .init("id", "The id given for it", .choice(ids)),
                .init("kind", "What the video is, in two to five words", .text),
                .init("category", "Which it is", .choice(["focus", "distracting"])),
            ]), count: ids.count...ids.count)),
        ])
    }

    static func prompt(for videos: [Pending], ids: [String], workingOn: [String]) -> String {
        var lines: [String] = []
        if !workingOn.isEmpty {
            lines.append("Lately they've been working in: \(workingOn.joined(separator: ", ")).")
        }
        lines.append("The videos:")
        for (id, video) in zip(ids, videos) {
            lines.append("\(id). “\(video.title)”")
        }
        return lines.joined(separator: "\n")
    }

    /// Verdicts for `videos`, asked a few at a time. A failed batch gets
    /// none; those videos are asked again when they're next watched.
    static func verdicts(for videos: [Pending], workingOn: [String], model: any OnDeviceModel,
                         now: Date) async -> [VideoVerdict] {
        var out: [VideoVerdict] = []
        var start = 0
        while start < videos.count {
            let batch = Array(videos[start..<min(start + batchSize, videos.count)])
            start += batchSize
            let ids = batch.indices.map { "v\($0 + 1)" }
            do {
                let answer = try await model.respond(Answer.self, instructions: instructions,
                                                     prompt: prompt(for: batch, ids: ids, workingOn: workingOn),
                                                     shape: shape(ids: ids))
                var seen = Set<String>()
                for item in answer.videos {
                    guard let index = ids.firstIndex(of: item.id), seen.insert(item.id).inserted else { continue }
                    let classification: Classification = item.category.lowercased() == "focus" ? .focus : .distraction
                    var kind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'."))
                    if kind.count > 40 { kind = String(kind.prefix(39)) + "…" }
                    out.append(VideoVerdict(videoId: batch[index].videoId, title: batch[index].title,
                                            kind: kind.isEmpty ? (classification == .focus ? "talk or tutorial" : "not about work") : kind.lowercased(),
                                            classification: classification, byUser: false, at: now))
                }
            } catch {
                Persistence.logger.error("smart categories: video batch failed: \(String(describing: error), privacy: .public)")
            }
        }
        return out
    }
}
