# ADR-003: Apple Intelligence als LLM im PoC

- Status: angenommen
- Datum: 2026-10-03

## Kontext
Im PoC soll nur ein lokales, kostenloses Modell genutzt werden, ohne Downloads.
Apple Intelligence (Framework `FoundationModels`, `SystemLanguageModel.default`) ist
Teil von macOS 27 und auf dem Mac aktiviert.

## Spike-Ergebnis (2026-10-03, MacBook M4 Pro, 24 GB, macOS 27.0)
| Prüfung | Ergebnis |
|---|---|
| Verfügbarkeit | `available` |
| Deutsch (`supportsLocale(de_DE)`) | ja |
| Kontextfenster (`contextSize`) | **8.192 Tokens** (Eingabe + Ausgabe) |
| Strukturierte Ausgabe (`@Generable`, Liste von Aussagen mit Belegstelle und Typ) | funktioniert, valides Ergebnis beim ersten Versuch |
| Belegstellen | 3 von 3 wörtlich im Quelltext |
| Vollständigkeit | lückenhaft: Zahl "mehr als 1300 Arten" und Größenangabe nicht extrahiert |
| Dialog (~180 Wörter) | 9 s, ca. 20 Wörter/s; inhaltlich korrekt, aber steif, und am Ende **unbelegte Zusatzaussagen** ("einzigartig", "neue Einblicke") |
| Token-Verbrauch Extraktion (Quelle ~120 Wörter) | 624 Tokens |

## Entscheidung
- `SystemLanguageModel.default` (auf dem Gerät) für alle LLM-Schritte des PoC. Nicht
  `PrivateCloudComputeLanguageModel`.
- Kleine Schritte, **eine neue `LanguageModelSession` pro Schritt**, Budget per
  `tokenCount(for:)` vor dem Aufruf prüfen.
- Quellen in Abschnitte von ca. 300–500 Wörtern teilen, Aussagen pro Abschnitt
  extrahieren. Ein zweiter Durchlauf fragt gezielt nach Zahlen und Daten, weil diese im
  Spike übersehen wurden.
- Belegstellen werden **im Code** gegen den Quelltext geprüft (normalisierter
  Teilstring-Vergleich). Aussagen ohne wörtliche Belegstelle werden verworfen.
- Skript abschnittsweise schreiben, jedes Segment strukturiert mit `claim_ids`. Danach
  Prüfung: Segmente mit Tatsachen ohne `claim_ids` bzw. mit Aussagen, die nicht zu den
  Aussagen passen, werden neu geschrieben oder entfernt. Abschluss-/Füllsätze der Personas
  dürfen keine neuen Fakten enthalten.
- Prompts als Textdateien im Bundle, nicht im Code.

## Folgen
- Folgen von 5–10 Minuten sind realistisch. Die reine Textgenerierung für ein
  10-Minuten-Skript (~1.300 Wörter) dauert grob 1–2 Minuten, dazu Extraktion je Quelle.
- Die Dialogqualität ist begrenzt. Mit Claude (nach dem PoC) wird sie deutlich besser.
