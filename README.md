<img src="Resources/Icon-1024.png" alt="App icon" width="128">

# EdgeSpeak

A native macOS app that reads PDFs and text aloud while it highlights what it is
reading. Synthesis streams in slices, so audio starts in seconds instead of waiting
for the whole document, and the sentence being spoken is highlighted in the PDF. With
an online voice the word being read is highlighted too. Native SwiftUI, macOS 14+.

![Swift](https://img.shields.io/badge/Swift-6-FA7343?logo=swift&logoColor=white&style=flat)
![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white&style=flat)
![arch](https://img.shields.io/badge/arch-arm64-blueviolet?style=flat)
![License](https://img.shields.io/badge/license-GPL--3.0-green?style=flat)
![Version](https://img.shields.io/badge/version-0.1.0-FF9F1C?style=flat)
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/gilsonolegario)

## Download

Grab the latest pre-built app from the [Releases page](https://github.com/gilsonolegario/edge-speak/releases) — or build it locally:

```bash
./build-app.sh    # macOS 14+ → EdgeSpeak.app (~280 MB, self-contained)
```

or run straight from the source tree (development mode; the bundled Python and voices are only packed by `build-app.sh`):

```bash
swift run EdgeSpeak
```

`build-app.sh` downloads a standalone Python base, the wheels and the Piper voices at build time and packs everything into the `.app`. See [First launch](#first-launch) for how to open the pre-built download the first time.

## First launch

The release download is **not notarized** — notarization requires a paid Apple
Developer account — so macOS blocks the first launch.

On macOS 15 (Sequoia) and later the old right-click → Open bypass is **gone**; use
this flow instead:

1. Double-click `EdgeSpeak.app` → the dialog says it can't be opened → click **Done**.
2. Open **System Settings → Privacy & Security → Security** (scroll to the bottom).
3. Under "Allow applications from", find *"EdgeSpeak was blocked to protect your Mac"* → click **Open Anyway** → confirm with your password.
4. Launch EdgeSpeak normally from now on.

On macOS 14 (Sonoma) you can still right-click the app → **Open** → **Open**.

> **Tip:** `Open Anyway` only appears for ~1 hour after the blocked launch. If you don't see it, double-click the app once more and go straight back to System Settings.
>
> **Troubleshooting:** if macOS claims the app is "damaged", remove the quarantine attribute once:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/EdgeSpeak.app
> ```

**Prefer to skip all of this?** Build locally — a `swift build` output never receives the quarantine attribute, so Gatekeeper stays out of the way (requires the Xcode Command Line Tools; the build script fetches the Python runtime and the voices).

## Major features

- **Streaming playback** — audio plays as each slice is synthesized; a 300-page PDF starts speaking in seconds.
- **Sentence highlighting in the PDF** — one highlight annotation per line box of the sentence, never the whole paragraph.
- **Word highlighting (karaoke)** — the online voice returns per-word timings, so the word being read is highlighted too.
- **Click to read from a sentence** — click any sentence in the PDF to start, or jump, the reading right there.
- **Footnotes** — a glued marker ("argument.7") is announced ("footnote 7") and the note body is read right after it; the *Read footnotes* option turns the whole thing off.
- **Two voices, one transport** — online (Microsoft neural, needs a network) or offline (Piper, local, no network).
- **Logic formulas spoken** — `∀`, `∃`, `⊢`, `∈`, `ℕ` … are expanded into words, with the pauses a classroom reading uses.
- **Filtered or full text** — strip headers, hyphenation and the bibliography, or read the document verbatim.
- **Audio export** — write the reading out as WAV or MP3.
- **No daemons, no telemetry** — nothing runs in the background and nothing is installed outside your home folder.

## Voices

Two voices in the same transport; switch from the toolbar selector or Settings → Reading.

- **Online (edge-tts)** — Microsoft neural voices, needs a network. Returns per-word timings, which is why word-level highlighting exists only here. If the service refuses, the app says so and suggests the offline voice instead of retrying in vain.
- **Offline (Piper)** — local synthesis, one sentence at a time, no word timings, so sentence highlighting only. Two voices ship inside the app: Faber (Portuguese) and Lessac (English). Credit and license (GPL-3.0) in [CREDITS.md](CREDITS.md).

## Reading and highlighting

- **Blue per sentence**: one highlight annotation per line box of the sentence — never the paragraph. Boxes come from the extractor in reading order, falling back to the paragraph when the sentence does not match.
- **Yellow per word** (online only): a global alignment between the spoken sequence and the PDF sequence. Where the PDF has a symbol and the voice has a phrase ("∃uT (u,o)" → "there exists u, such that, T of u"), the expansion word gets **no box** instead of stealing a later prose box — that is what used to make the yellow jump side to side. Repeated words resolve by context (±3), not by the first occurrence.
- **Scrolling**: automatic follow can be turned off, and manual scrolling always wins. With follow off, the **Go to passage** button returns to the reading point. Clicking a sentence **plays from it**: with no audio yet, synthesis starts at the clicked sentence instead of the beginning; with audio, the jump goes straight to the slice, without waiting for timings not yet measured.
- **Footnotes** (on by default): the glued marker ("argument.7") is announced ("footnote 7") and the body is read right after — the importer moves it to after the marker's sentence without changing the other sentences' indices. Honest limit: in a PDF whose text layer does not carry the note body, only the marker is announced.

## Logic formulas

The spoken filter (`ReadAloudFilter`) expands the notation in the voice's language, with the pauses a classroom reading uses. Coverage (EN/PT):

- Quantifiers ∀ ∃ ∃! with a variable, modals □ ◇, turnstiles ⊢ ⊨ and negations ⊬ ⊭, ASCII `|-` `|=` `->` `=>` `<->`.
- Sets ∈ ∉ ⊆ ∪ ∩ ∖ ∅ ℘, set-builder `{x | φ}` / `{x : φ}`, horseshoe ⊃ by context (superset between sets, conditional between formulas).
- Greek by name, blackboard-bold ℕ ℤ ℚ ℝ ℂ, iota ℩, Quine corners, primes p′ ("p prime"), §2 ("section 2"), functors ("T of u, o"), R_H.
- Comparisons `<=` `>=` `!=` `<>` `/=`, identity, ⊥/⊤.
- **Deliberate silence**: `[]`/`<>` as a modal, `x` in "3 x 4" as "times", a lone bar outside a set-builder — verbalizing them would break ordinary prose.

Known limit: quality depends on the PDF text layer; a symbol that arrives as an image is not read.

## How to install and use the app

1. Download `EdgeSpeak-vX.Y.Z-macos-arm64.zip` from the [Releases page](https://github.com/gilsonolegario/edge-speak/releases) and unzip it.
2. Drag `EdgeSpeak.app` to your Applications folder.
3. Open it. If macOS blocks it, follow [First launch](#first-launch).
4. Click **Open** in the toolbar and pick a PDF, Markdown or text file — or drop a file onto the icon.
5. Press **Enter** to play/pause. The sentence being read is highlighted in the PDF.
6. Click any sentence in the PDF to read from there.
7. Open **Settings (⌘,)** to choose the voice, rate, follow mode and interface language.

### Shortcuts

| Key | Action |
|---|---|
| Enter | Play / pause |
| Space | Play / pause (outside the editor and the PDF) |
| ⌥← / ⌥→ | Jump 15 s back / forward |
| ⌘. | Stop synthesis |

## macOS compatibility

| Version | Notes |
|---|---|
| macOS 14 (Sonoma) | supported |
| macOS 15 (Sequoia) | supported |

The pre-built download is `arm64` (Apple Silicon) only.

## Settings

Three tabs:

- **Reading** — voice, rate, follow the reading, PT/EN interface language.
- **Text** — typeface, full text, read footnotes.
- **Advanced** — on-disk cache size and a clear button.

Everything persists between sessions. The interface is available in Portuguese and English, switched on the fly (Portuguese by default).

## Build

Requires macOS 14+ and the Swift toolchain (SwiftPM).

```bash
swift build
swift test
./build-app.sh   # → EdgeSpeak.app (~280 MB) at the project root
```

`build-app.sh` downloads the Python base, the wheels and the voices **at build time** and packs the `.app` with everything inside (details in the script header). On first run the app prepares a Python venv in `Application Support/EdgeSpeak` from what ships in the bundle; cached audio lives in `Caches/EdgeSpeak`. Nothing is installed as a daemon and nothing runs in the background.

The package builds one target, `EdgeSpeak`, from `Sources/EdgeSpeak/`; tests are in `Tests/EdgeSpeakTests/` (swift-testing, `@Test`/`#expect`).

## Pricing

EdgeSpeak is free and always will be. No license keys, no accounts, no telemetry.

## Documentation

- **Layer-by-layer contract** (files, functions and rules) — [INTERFACE.md](INTERFACE.md)
- **Third-party credits and licenses** — [CREDITS.md](CREDITS.md)
- **Research notes** (PyMuPDF, PDF types, OSS survey, audits) — [docs/pesquisas/](docs/pesquisas/)

## History

**0.1.0** — First release: streaming synthesis with sentence and word highlighting, click-to-read from a sentence, footnote markers announced with the body linked right after, logic-formula expansion, PT/EN interface, three-tab Settings, audio export and per-document resume.

## Known limits

- The first seconds of audio may play without a highlight in the PDF — cause not yet isolated (the slice arrives and plays before the highlight settles; reproducible but not explained).
- Footnote bodies in PDFs whose text layer does not carry them (such as the test article): the marker is announced, the body does not exist to be read.
- The online voice depends on the Microsoft endpoint; an outage shows up as a message, not a freeze.

## License

EdgeSpeak is released under the [GPL-3.0 License](LICENSE). Piper (GPL-3.0) and PyMuPDF (AGPL) ship with the app — see [CREDITS.md](CREDITS.md).

---

Built with [opencode](https://opencode.ai) — the open-source AI coding agent.
