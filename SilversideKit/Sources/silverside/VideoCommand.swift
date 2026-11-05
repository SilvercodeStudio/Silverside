import ArgumentParser
import Foundation
import SilversideKit

struct VideoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video",
        abstract: "Make a video of a CD+G disc's rip: the graphics over the audio, with a chapter for each track.",
        discussion: """
            A rip of a disc with CD+G graphics (karaoke lyrics, pictures) keeps each track's graphics as a .cdg file. \
            video draws them as a CD+G player does, over the rip's audio, in one .m4v file for the whole disc, with a \
            chapter for each track, named by its title. The audio is Apple Lossless, the rip's audio exactly, or AAC, \
            for a smaller file. A CD+EG disc's video shows its 256 colors, as a CD+EG player does (a Sega Saturn, \
            for one), or with --picture g its 16-color CD+G picture, as a CD+G player shows it.

            The video goes into the album folder when the rip was encoded (the album's report then lists it, so that \
            an update of the library renames it with the album), else into the rip's folder; it is named after the \
            album. An album in the library whose rip is gone works too, if it is lossless and has its .cdg files.

            Examples:
              silverside video "<rip folder>"
              silverside video "<album folder>/Rip Report.json" --audio aac
              silverside video "<rip folder>" -o ~/Movies/Karaoke.m4v --codec hevc
            """)

    @Argument(help: "The rip's folder (with disc.json and the .cdg files), or an album's \"Rip Report.json\".")
    var folder: String

    @Option(
        name: .shortAndLong,
        help: "The video file. Default: in the album folder, else the rip's, named after the album.")
    var output: String?

    @Option(help: "The audio: appleLossless (the rip's audio exactly) or aac (smaller).")
    var audio: CDGraphicsVideo.Audio = .appleLossless

    @Option(
        help: """
            For a disc with CD+EG graphics: the picture in 256 colors (eg), as a CD+G player shows it in 16 (g), \
            named "<album> (CD+G).m4v", or both.
            """)
    var picture: CDGraphicsVideo.Pictures = .eg

    @Option(help: "The video codec: h264 (plays everywhere) or hevc (smaller files).")
    var codec: CDGraphicsVideo.Codec = .h264

    @Option(help: "How many pixels wide and high each pixel of the CD+G screen (300 × 216) becomes.")
    var scale = 4

    func validate() throws {
        guard (1...8).contains(scale) else { throw ValidationError("--scale is from 1 to 8.") }
        if output != nil && picture == .both { throw ValidationError("--picture both makes two files: leave out -o.") }
    }

    func run() async throws {
        let url = URL(filePath: (folder as NSString).expandingTildeInPath)
        let disc =
            url.pathExtension == "json" ? try RippedDisc(albumReportAt: url) : try RippedDisc(folder: url)
        let chapters = try CDGraphicsVideo.chapters(of: disc)
        var video = CDGraphicsVideo()
        video.codec = codec
        video.scale = scale
        video.audio = audio
        let progress = ProgressLine()
        // A CD+G disc has one picture.
        let pictures = CDGraphicsVideo.hasExtendedGraphics(disc.report) ? picture.pictures : [.extended]
        for picture in pictures {
            let started = ContinuousClock.now
            let show = { (fraction: Double) in progress.showText(String(format: "Video: %3.0f%%", fraction * 100)) }
            video.picture = picture
            let target: URL
            if let output {
                target = URL(filePath: (output as NSString).expandingTildeInPath)
                video.title = disc.release?.title
                video.artist = disc.release?.artist
                try video.write(chapters, to: target, progress: show)
            } else {
                target = try video.write(disc, progress: show)
            }
            progress.clear()
            let seconds = Int((ContinuousClock.now - started).components.seconds)
            print(
                "\(target.path): \(chapters.count) chapters, written in \(seconds / 60):"
                    + String(format: "%02d", seconds % 60) + ".")
        }
        for (number, chapter) in chapters.enumerated() {
            print(
                String(format: "  %2d  ", number + 1) + chapter.title
                    + (chapter.graphics == nil ? " (no graphics)" : ""))
        }
    }
}

extension CDGraphicsVideo.Codec: ExpressibleByArgument {}
