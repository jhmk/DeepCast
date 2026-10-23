# ADR-004: Suche (DuckDuckGo + Wikipedia) und Sprachausgabe im PoC

- Status: angenommen
- Datum: 2026-10-03

## Suche

### Kontext
Im PoC keine kostenpflichtigen oder key-pflichtigen APIs. Das Claude Web-Search-Tool
ist zu teuer und liefert nur verschlüsselte Inhalte (siehe Spec, Abschnitt 3).

### Entscheidung
- Protocol `SearchProvider`, im PoC zwei Implementierungen:
  - **Wikipedia** (offizielle MediaWiki-API, DE/EN, kein Key): Vertrauensstufe B.
  - **DuckDuckGo** über die HTML-Seite `html.duckduckgo.com`. Es gibt keine offizielle
    API; die Nutzung ist inoffiziell und kann jederzeit brechen oder blockiert werden.
    Deshalb: höflicher User-Agent, max. ca. 1 Anfrage pro Sekunde, wenige Anfragen pro
    Episode, Fehler führen nicht zum Abbruch (Wikipedia allein reicht für einen Lauf).
- Volltexte werden selbst abgerufen und in Swift extrahiert. Vertrauensstufe über eine
  Domain-Liste (unbekannte Seiten: C).
- Nach dem PoC: Brave Search API oder Tavily.

## Sprachausgabe

### Spike-Ergebnis (2026-10-03)
| Stimme | Identifier | Qualität | Ergebnis |
|---|---|---|---|
| Anna (Premium) | `com.apple.voice.premium.de-DE.Anna` | 3 | Rendern in Datei per `AVSpeechSynthesizer.write` funktioniert, 9,2 s Audio in 1,9 s |
| Martin (Enhanced) | `com.apple.ttsbundle.siri_Martin_de-DE_premium` | 2 | funktioniert, 8,4 s Audio in 1,1 s |

- Ausgabeformat: PCM Float32, 22.050 Hz, mono.
- **Stolperfalle:** Die Systemnamen enthalten den Qualitätszusatz ("Anna (Premium)").
  Ein Vergleich auf den exakten Namen "Anna" liefert still die Compact-Stimme. Lösung:
  `VoiceCatalog.bestVoice(named:)` vergleicht den Basisnamen und nimmt die höchste
  Qualität.

### Entscheidung
- `AVSpeechSynthesizer.write(_:toBufferCallback:)` pro Segment, Cache per Hash aus
  Text + Stimmen-ID + Tempo.
- ffmpeg setzt die Segmente zusammen, rechnet auf 44,1 kHz hoch, normalisiert auf
  −16 LUFS und schreibt M4A (AAC) mit Kapiteln.
- Standard-Personas: Max → Martin (Erweitert), Dr. Lena → Anna (Premium). Weitere
  Sprecher nutzen Standard-Stimmen und werden in der UI als "eingeschränkt" markiert.
- `say -o` bleibt als Ausweichweg, wird aber nicht benötigt.
