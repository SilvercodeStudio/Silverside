import CDRipKit
import Foundation

/// Turns Ctrl-C into a clean stop. The first Ctrl-C stops the work after the read under
/// way, through its `StopToken`, so the files written so far are kept and the rip folder's
/// claim is released. A second Ctrl-C ends the process at once.
final class Interrupt {
    private let source: any DispatchSourceSignal

    init(stop: StopToken, message: String) {
        // The default handler would end the process; the source hears the signal instead.
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            if stop.isStopped { exit(130) }
            stop.stop()
            print("\n" + message)
        }
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
