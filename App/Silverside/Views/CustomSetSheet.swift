import SilversideKit
import SwiftUI

/// Puts a disc that MusicBrainz does not know in a set of the user's own (`CustomSet`): a new
/// one, or one made for another disc of the box. CD-Text's album title, such as "Seven Classic
/// LPs [Disc 2]", fills in the set's name and the disc's number, and finds a set already made
/// for the box. The set stays on this Mac; it is never sent to MusicBrainz.
struct CustomSetSheet: View {
    let toc: TOC
    /// The disc's set now, if it is in one.
    let current: CustomSet?
    var onSave: (CustomSet, Int) -> Void
    var onLeave: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private let sets: [CustomSet]
    /// "" for a new set, else the ID of the set to put the disc in.
    @State private var choice: String
    @State private var title: String
    @State private var artist: String
    @State private var discCount: Int
    @State private var position: Int

    /// `albumTitle` and `artist` are the disc's names now; `albumTitle` may end in its number.
    init(
        toc: TOC, albumTitle: String, artist: String, current: CustomSet?, onSave: @escaping (CustomSet, Int) -> Void,
        onLeave: (() -> Void)? = nil
    ) {
        self.toc = toc
        self.current = current
        self.onSave = onSave
        self.onLeave = onLeave
        let sets = CustomSetStore().sets()
        self.sets = sets
        let hint = CDTextHints.disc(inAlbumTitle: albumTitle)
        let named = hint?.title ?? albumTitle
        if let current, let disc = current.disc(with: toc) {
            _choice = State(initialValue: current.id)
            _position = State(initialValue: disc.position)
        } else if let found = Self.set(in: sets, named: named, artist: artist) {
            _choice = State(initialValue: found.id)
            _position = State(initialValue: hint?.position ?? found.freePositions.first ?? 1)
        } else {
            _choice = State(initialValue: "")
            _position = State(initialValue: hint?.position ?? 1)
        }
        _title = State(initialValue: named)
        _artist = State(initialValue: artist)
        _discCount = State(initialValue: max(hint?.count ?? 2, hint?.position ?? 1, 2))
    }

    /// The set made for the same box: the same title and artist, as CD-Text gives them.
    static func set(in sets: [CustomSet], named title: String, artist: String) -> CustomSet? {
        sets.first {
            $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
                && $0.artist.localizedCaseInsensitiveCompare(artist) == .orderedSame
        }
    }

    private var chosen: CustomSet? { sets.first { $0.id == choice } }
    private var count: Int { chosen?.discCount ?? discCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(current == nil ? "Part of a Set" : "Set").font(.title2.weight(.semibold))
            Text(
                "MusicBrainz does not know this disc. Put it in a set of your own, as the other discs of its box go in, and they become one album: one folder, the disc numbers in the tags, and the album's names and cover for every disc. The set stays on this Mac; it is not sent to MusicBrainz."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Form {
                if !sets.isEmpty {
                    Picker("Set", selection: $choice) {
                        Text("New Set").tag("")
                        Divider()
                        ForEach(sets) { set in
                            Text("\(set.title) · \(set.artist) · \(set.discCount) discs").tag(set.id)
                        }
                    }
                }
                if chosen == nil {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    Stepper(value: $discCount, in: max(position, 2)...99) {
                        Text("Discs: \(discCount)").monospacedDigit()
                    }
                }
                Picker("This disc", selection: $position) {
                    ForEach(1...max(count, 1), id: \.self) { number in
                        Text(label(for: number)).tag(number)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                if let onLeave, current != nil {
                    Button("Leave the Set") {
                        onLeave()
                        dismiss()
                    }
                    .help("This disc becomes an album of its own again, with the names it has now.")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(current == nil ? "Add to Set" : "Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil && (title.trimmed.isEmpty || artist.trimmed.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: choice) {
            if let chosen, chosen.disc(with: toc) == nil, chosen.disc(at: position) != nil {
                position = chosen.freePositions.first ?? position
            }
            position = min(position, count)
        }
    }

    /// "Disc 2", and whether another disc is there already.
    private func label(for number: Int) -> String {
        guard let disc = chosen?.disc(at: number), disc.discID != toc.musicBrainzDiscID else { return "Disc \(number)" }
        return "Disc \(number) (in place of the disc there now)"
    }

    private func save() {
        let set =
            chosen
            ?? CustomSet(title: title.trimmed, artist: artist.trimmed, discCount: max(discCount, position))
        onSave(set, position)
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
