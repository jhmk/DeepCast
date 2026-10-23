# DeepCast

Personal AI-assisted macOS podcast generator.

DeepCast explores a local-first workflow for turning a topic or question into a sourced audio episode: research planning, source collection, claim extraction, fact checking, script generation, text-to-speech, audio post-processing, transcript and shownotes.

The project is intentionally designed as an operator tool rather than a generic demo: every important intermediate result should be inspectable, reviewable and reproducible.

## Core ideas

- Multi-step AI pipeline instead of one-shot generation
- Sources and claims first, script second
- Fact-checking with explicit claim IDs and evidence snippets
- Review pause before script and audio generation
- Local macOS app with SwiftUI
- Provider abstraction for local and cloud LLM/TTS providers
- API keys in macOS Keychain, never in files or logs
- Audio export with transcript, chapters and shownotes

## Current status

Prototype / personal research project. The SwiftUI app and architecture are under active development. The public project overview lives in `docs/project-overview.md`; architecture notes live in `docs/adr/`.

## Repository structure

```text
app/              SwiftUI macOS app
app/DeepCast/     Application source
docs/adr/         Architecture decision records
docs/project-overview.md  Public project overview
```

## Build

```bash
cd app
xcodegen generate
xcodebuild -project DeepCast.xcodeproj -scheme DeepCast -destination 'platform=macOS' -derivedDataPath build test
```

`xcodegen` is expected for regenerating the Xcode project from `app/project.yml`.

## Privacy / publication notes

Generated episodes, audio files, caches, local API-key files and build artifacts are ignored. Real API keys should live in Keychain or local untracked config only.
