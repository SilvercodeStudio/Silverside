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
            chapter for each track, named by its title. The audio is Apple Lossless, the rip's audio exactly. A CD+EG \
            disc's video has its CD+G pictures.

            Examples:
              silverside video "<rip folder>"
              silverside video "<rip folder>" -o ~/Movies/Karaoke.m4v --codec hevc
            """)

    @Argument(help: "The rip's folder (with disc.json and the .cdg files).")
    var folder: String

    @Option(name: .shortAndLong, help: "The video file. Default: in the rip's folder, named after it.")
    var output: String?

    @Option(help: "The video codec: h264 (plays everywhere) or hevc (smaller files).")
    var codec: CDGraphicsVideo.Codec = .h264

    @Option(help: "How many pixels wide and high each pixel of the CD+G screen (300 × 216) becomes.")
    var scale = 4

    func validate() throws {
        guard (1...8).contains(scale) else { throw ValidationError("--scale is from 1 to 8.") }
    }

    func run() async throws {
        let url = URL(filePath: (folder as NSString).expandingTildeInPath)
        let disc = try RippedDisc(folder: url)
        let chapters = try CDGraphicsVideo.chapters(of: disc)
        let target =
            output.map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            ?? url.appending(path: url.lastPathComponent + ".m4v")
        var video = CDGraphicsVideo()
        video.codec = codec
        video.scale = scale
        let progress = ProgressLine()
        let started = ContinuousClock.now
        try video.write(chapters, to: target) { fraction in
            progress.showText(String(format: "Video: %3.0f%%", fraction * 100))
        }
        progress.clear()
        let seconds = Int((ContinuousClock.now - started).components.seconds)
        print(
            "\(target.path): \(chapters.count) chapters, written in \(seconds / 60):\(String(format: "%02d", seconds % 60))."
        )
        for (number, chapter) in chapters.enumerated() {
            print(
                String(format: "  %2d  ", number + 1) + chapter.title
                    + (chapter.graphics == nil ? " (no graphics)" : ""))
        }
    }
}

extension CDGraphicsVideo.Codec: ExpressibleByArgument {}
