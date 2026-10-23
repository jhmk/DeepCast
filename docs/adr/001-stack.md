# ADR-001: Stack der App

- Status: angenommen
- Datum: 2026-10-03

## Kontext
DeepCast ist eine persönliche Mac-App (kein App Store). Der Proof of Concept (Spec,
Abschnitt 0) soll nur lokal und kostenlos laufen.

## Entscheidung
- SwiftUI-App, Swift 6 mit `SWIFT_STRICT_CONCURRENCY = complete`, `@Observable`,
  SwiftData für die Bibliothek. Mindestversion macOS 27, Apple Silicon.
- Projekt wird mit **XcodeGen** aus `app/project.yml` erzeugt. Die `.xcodeproj` ist nicht
  im Repo (`xcodegen generate` vor dem Build).
- Tests mit Swift Testing (`DeepCastTests`).
- **Keine App Sandbox**, Ad-hoc-Signatur (`CODE_SIGN_IDENTITY = -`), kein Hardened
  Runtime: Die App startet ffmpeg als Prozess und schreibt nach `~/Music/DeepCast` und
  iCloud Drive. Für eine rein persönliche App ist das vertretbar.
- Externe Werkzeuge (ffmpeg) werden über feste Homebrew-Pfade gesucht, weil GUI-Apps den
  PATH der Shell nicht erben (`ExecutableLocator`).
- UI-Texte auf Deutsch als Quellsprache, String Catalog (`Localizable.xcstrings`), Englisch
  später.

## Build
```
cd app
xcodegen generate
xcodebuild -project DeepCast.xcodeproj -scheme DeepCast -derivedDataPath build test
open build/Build/Products/Debug/DeepCast.app
```

## Folgen
- Keine Abhängigkeiten von Drittanbieter-Paketen im PoC.
- Für eine spätere Verteilung (M7) müssten Sandbox/Signierung neu bewertet werden.
