# AGENTS.md – Hinweise für Coding-Assistenten

DeepCast ist eine persönliche macOS-App, die zu einem Thema recherchiert, Fakten prüft und
daraus einen Podcast mit mehreren Sprechern erzeugt.

## Zuerst lesen
- `docs/project-overview.md` – öffentliche Projektübersicht.
- `docs/adr/` – Architekturentscheidungen (aktuell bis ADR-012).
- Stilfragen der Folgen (wie ein Podcast klingen soll) gehören **nicht** in Code oder Prompts,
  sondern in den Podcast-Leitfaden: `app/DeepCast/Resources/Leitfaden/Podcast-Leitfaden.md`
  (Standard) bzw. die vom Nutzer bearbeitete Kopie in
  `~/Library/Application Support/DeepCast/Podcast-Leitfaden.md`.

## Arbeitsweise (vom Nutzer festgelegt)
- Fragen zuerst nur beantworten. Code, Dateien und Einstellungen erst nach ausdrücklicher
  Freigabe („Leg los“) ändern.
- Keine Live-Tests, die Gratis-Kontingente verbrauchen, und keine Änderungen am Schlüsselbund
  ohne Freigabe.
- Keine API-Keys in Dateien, Logs oder Commits. Keys liegen im Schlüsselbund (`local.deepcast`)
  oder – falls vom Nutzer gewählt – in `~/Library/Application Support/DeepCast/keys.json`.
- Keine API-Keys oder privaten Provider-Konfigurationen in Dateien, Logs oder Commits.
- Kleine, fokussierte Commits (Conventional Commits), Antworten auf Deutsch, Code/Kommentare Englisch.

## Bauen und testen
```
cd app
xcodegen generate
xcodebuild -project DeepCast.xcodeproj -scheme DeepCast -destination 'platform=macOS' -derivedDataPath build test
open build/Build/Products/Debug/DeepCast.app
```
- Tests laufen ohne Netz und ohne Schlüsselbund (`KeychainStore.isDisabled` im Testmodus).
- Live-Tests sind mit `.tags(.live)` markiert und laufen nur mit `TEST_RUNNER_DEEPCAST_*`-Variablen.
- Swift 6 strict concurrency, keine Warnungen zulassen.

## Architektur in Kürze
- `Pipeline/LocalPipeline.swift`: Recherche → Review-Pause → Erzählplan → Skript → Testhörer →
  Überarbeitung → Faktenprüfung. Prompts in `Resources/Prompts/*.txt`.
- `FactCheck/`: deterministische Regeln (Belege, Zahlen, Einheiten, Zitate, Ampel, Skript-Prüfung,
  Qualitätsmessung). Faktenregeln bleiben im Code – der Leitfaden steuert nur den Stil.
- `Speech/`, `Audio/`: Fish Audio / Apple, ffmpeg-Kette (Klang, −16 LUFS, Kapitel).
