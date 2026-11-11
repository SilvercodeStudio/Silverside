# Command Line Tool

The `silverside` command does what the app does, from Terminal: it rips, repairs, checks, encodes, and looks up names, with the same engine and the same settings file. Use it for scripts, for a Mac without a screen nearby, or if you like a terminal. The app and the command can run at the same time, on different drives.

<!-- toc -->

## Install it

The command comes inside the app. Choose **Silverside › Install Command Line Tool…** (or the button in Settings › General), choose a folder, and click Install:

- **/usr/local/bin** is on every shell's PATH. It may ask for an administrator's password.
- **~/.local/bin** needs no password, but your shell must have it on its PATH. The window says if it does not; for zsh, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zprofile`.

Silverside puts links to the command, and to its completions for zsh, bash, and fish, in that folder. Because they are links into the app, each update of the app updates the command too. If you move the app to another folder, install the command again. **Remove** in the same window takes the links away.

To check it, open a new Terminal window and type:

```sh
silverside --version
```

A copy of Silverside built from its source code has the command too; `make install` copies it into a folder instead of linking it.

## Get started

```sh
silverside drives                     # the drives, and the disc in each
silverside info -d asus               # the disc: tracks, ISRCs, disc IDs
silverside rip -d asus                # rip to WAV files, verify, repair
silverside rip -d disk14 --encode     # rip, then encode into the library
silverside encode -i "<rip folder>"   # encode a rip later
```

`-d` names the drive: its short name, which `silverside drives` shows (such as `asus` or `bu50n`), any part of its name that only one drive has, or the disc's BSD name (`disk14`). With one disc in one drive, leave `-d` out.

The first rip at a terminal asks you to agree to rip only discs that you own, for your personal use, as the app does. The answer is kept in the settings, so if you agreed in the app, the command does not ask.

Press Control-C to stop a rip. As Stop does in the app, it lets the read under way finish, and keeps the tracks done so far for the next rip of the disc.

## Commands

| Command | What it does |
|---|---|
| `drives` | The drives, their discs, read offsets, and caches; sets an offset by hand |
| `info` | A disc's tracks, pregaps, ISRCs, MCN, CD-Text, and disc IDs |
| `rip` | Rips a disc: verifies, re-reads, repairs, names it, and can encode it |
| `repair` | Repairs rips again with CTDB, with the disc in a drive or from several rips |
| `check` | Looks earlier rips up in AccurateRip and CTDB again (Check Again) |
| `metadata` | The MusicBrainz releases for a disc; changes names and covers |
| `encode` | Encodes rips into the library |
| `video` | A video of a CD+G disc's graphics |
| `hdcd` | Looks for HDCD codes in audio files |
| `config` | Shows and changes the settings |
| `eject` | Ejects a disc |
| `cdtext`, `license` | A disc's CD-Text in full; the license |

## Learn more

- `silverside --help` lists the commands, and `silverside help rip` (or any other command) explains one, with each option and examples.
- The settings are the app's: a change with `silverside config` shows in Settings, and the other way around. `silverside config` alone shows them all.
- Options on the command line apply to one run only, such as `rip --encode` or `rip --tracks 1,3-5`; the settings apply to every run.
- The full guide to the command is [cli.md](https://github.com/SilvercodeStudio/Silverside/blob/main/docs/cli.md) on GitHub: every command, what a rip makes, and every setting.
