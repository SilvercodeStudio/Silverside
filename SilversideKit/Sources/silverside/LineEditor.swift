import Foundation

/// A line read at the terminal with text in it already, to edit: ← and → (Option for a word),
/// Home and End (Control-A, Control-E), Backspace and Delete, Control-U and Control-K (to the
/// start or end), Control-W (a word back); ↑ and ↓ put each of `choices` in its place. Return
/// takes the line; Control-C stops. A line that wraps is redrawn whole.
enum LineEditor {
    struct Stopped: Error {}

    /// The line as edited. Without a terminal, a line read as typed, or `text` when it is empty.
    static func read(prompt: String, text: String, choices: [String] = []) throws -> String {
        var original = termios()
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0, tcgetattr(STDIN_FILENO, &original) == 0 else {
            print(prompt + text)
            return text
        }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSADRAIN, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSADRAIN, &original) }

        var editor = Editor(prompt: prompt, buffer: Array(text), choices: choices.isEmpty ? [text] : choices)
        editor.cursor = editor.buffer.count
        editor.choice = editor.choices.firstIndex(of: text) ?? 0
        editor.draw()
        while let key = readKey() {
            switch key {
            case .enter:
                editor.cursor = editor.buffer.count
                editor.draw()
                write("\r\n")
                return String(editor.buffer)
            case .stop:
                write("\r\n")
                throw Stopped()
            default:
                editor.handle(key)
                editor.draw()
            }
        }
        write("\r\n")
        throw Stopped()
    }

    enum Key: Equatable {
        case character(Character)
        case enter, stop, backspace, delete, left, right, wordLeft, wordRight
        case home, end, killToStart, killToEnd, killWord, up, down, other
    }

    struct Editor {
        var prompt: String
        var buffer: [Character]
        var choices: [String]
        var choice = 0
        var cursor = 0
        /// Rows from the prompt's first row down to the cursor's, as last drawn.
        var cursorRow = 0

        mutating func handle(_ key: Key) {
            switch key {
            case .character(let character):
                buffer.insert(character, at: cursor)
                cursor += 1
            case .backspace where cursor > 0:
                cursor -= 1
                buffer.remove(at: cursor)
            case .delete where cursor < buffer.count: buffer.remove(at: cursor)
            case .left: cursor = max(0, cursor - 1)
            case .right: cursor = min(buffer.count, cursor + 1)
            case .wordLeft: cursor = wordStart(before: cursor)
            case .wordRight:
                while cursor < buffer.count, buffer[cursor] == " " { cursor += 1 }
                while cursor < buffer.count, buffer[cursor] != " " { cursor += 1 }
            case .home: cursor = 0
            case .end: cursor = buffer.count
            case .killToStart:
                buffer.removeSubrange(0..<cursor)
                cursor = 0
            case .killToEnd: buffer.removeSubrange(cursor...)
            case .killWord:
                let start = wordStart(before: cursor)
                buffer.removeSubrange(start..<cursor)
                cursor = start
            case .up, .down:
                choice = (choice + (key == .up ? choices.count - 1 : 1)) % choices.count
                buffer = Array(choices[choice])
                cursor = buffer.count
            default: break
            }
        }

        func wordStart(before index: Int) -> Int {
            var at = index
            while at > 0, buffer[at - 1] == " " { at -= 1 }
            while at > 0, buffer[at - 1] != " " { at -= 1 }
            return at
        }

        /// Draws the prompt and the line again from the prompt's first row, and puts the cursor
        /// in its place, counting rows as the terminal wraps them.
        mutating func draw() {
            let width = max(LineEditor.columns(), 10)
            let start = prompt.count
            let end = start + buffer.reduce(0) { $0 + LineEditor.width($1) }
            let at = start + buffer[..<cursor].reduce(0) { $0 + LineEditor.width($1) }
            var out = cursorRow > 0 ? "\u{1B}[\(cursorRow)A" : ""
            out += "\r" + prompt + String(buffer) + "\u{1B}[J"
            // At the last column, the terminal waits to wrap until the next character.
            if end > 0, end % width == 0 { out += "\r\n" }
            let endRow = end / width
            let row = at / width
            if endRow > row { out += "\u{1B}[\(endRow - row)A" }
            out += "\r"
            if at % width > 0 { out += "\u{1B}[\(at % width)C" }
            cursorRow = row
            LineEditor.write(out)
        }
    }

    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func columns() -> Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
    }

    /// Columns that a character takes: two for East Asian wide characters and emoji.
    static func width(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        let value = scalar.value
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD,
        ]
        return wide.contains { $0.contains(value) } || scalar.properties.isEmojiPresentation ? 2 : 1
    }

    static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 1 { return byte }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }

    /// The next key: a character (UTF-8, as many bytes as its first says), a control key, or an
    /// escape sequence for the arrows, Home, End, and Delete.
    static func readKey() -> Key? {
        guard let byte = readByte() else { return nil }
        switch byte {
        case 0x0D, 0x0A: return .enter
        case 0x03, 0x04: return .stop
        case 0x7F, 0x08: return .backspace
        case 0x01: return .home
        case 0x05: return .end
        case 0x02: return .left
        case 0x06: return .right
        case 0x15: return .killToStart
        case 0x0B: return .killToEnd
        case 0x17: return .killWord
        case 0x10: return .up
        case 0x0E: return .down
        case 0x1B: return readEscape()
        case 0x00..<0x20: return .other
        default:
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            var bytes = [byte]
            while bytes.count < length, let next = readByte() { bytes.append(next) }
            return String(decoding: bytes, as: UTF8.self).first.map { .character($0) } ?? .other
        }
    }

    static func readEscape() -> Key {
        guard let next = readByte() else { return .other }
        switch next {
        case UInt8(ascii: "b"): return .wordLeft
        case UInt8(ascii: "f"): return .wordRight
        case UInt8(ascii: "O"):
            switch readByte() {
            case UInt8(ascii: "H"): return .home
            case UInt8(ascii: "F"): return .end
            default: return .other
            }
        case UInt8(ascii: "["):
            // Parameters, then a final byte from @ to ~: "[C", "[3~", "[1;3D".
            var parameters = ""
            while let byte = readByte() {
                if (0x40...0x7E).contains(byte) {
                    let word = parameters.hasSuffix(";3") || parameters.hasSuffix(";9")
                    switch (byte, parameters) {
                    case (UInt8(ascii: "A"), _): return .up
                    case (UInt8(ascii: "B"), _): return .down
                    case (UInt8(ascii: "C"), _): return word ? .wordRight : .right
                    case (UInt8(ascii: "D"), _): return word ? .wordLeft : .left
                    case (UInt8(ascii: "H"), _): return .home
                    case (UInt8(ascii: "F"), _): return .end
                    case (UInt8(ascii: "~"), "1"), (UInt8(ascii: "~"), "7"): return .home
                    case (UInt8(ascii: "~"), "4"), (UInt8(ascii: "~"), "8"): return .end
                    case (UInt8(ascii: "~"), "3"): return .delete
                    default: return .other
                    }
                }
                parameters.append(Character(Unicode.Scalar(byte)))
            }
            return .other
        default: return .other
        }
    }
}
