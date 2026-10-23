# ADR-008: Funktionsausbau ohne Live-Tests (Stunde allein)

- Status: angenommen
- Datum: 2026-10-03
- Rahmen: keine Live-Aufrufe, kein Schlüsselbund-Zugriff in Tests, nur Gratis-Modelle.

## Umgesetzt
| Bereich | Entscheidung |
|---|---|
| Modelle | `ModelRef` (Anbieter + Modell, gespeichert als `anbieter|modell`, alte Werte werden migriert). Standard: Schreiber Qwen3.8 27B `:free` (OpenRouter), Prüfer `gemini-3.5-flash-lite` (Google). Auswahllisten in Einstellungen → KI, nur Gratis-Modelle; „Liste aktualisieren“ lädt auf Knopfdruck die aktuellen `:free`-Modelle (OpenRouter) und Gemini/Gemma-Textmodelle (Google). Ketten: gewählter Schreiber → Qwen → Gemini Flash-Lite → Apple; Prüfer zuerst, dann Schreib-Kette. |
| Quellen | Standard-Quellen pro Episode einstellbar; Domain-Liste (vertrauen = mind. B, abwerten = eine Stufe tiefer, sperren); spezifischste Regel gewinnt. |
| Aussprache | Wörterbuch (ganze Wörter) vor der Sprachausgabe; Transkript behält Schreibweise. Deutsche Zahlen werden für Fish ausgeschrieben (Fish normalisiert nur EN/ZH). |
| Editor | Bearbeitete Segmente werden live geprüft (gleiche Regeln wie Skript-Prüfung), Belege per Menü zuordnen, „Mit KI neu schreiben“ (closed book, optionaler Wunsch). |
| Fortsetzen | `ResearchCheckpoint` in `dossier.json`: Plan, Quellen, ausgewertete Quellen und geprüfte Aussagen werden übernommen. Alte Dossiers ohne Checkpoint gelten als abgeschlossen. |
| Faktencheck | Syndizierung (5-Wort-Shingles, Containment ≥ 0,5) → gemeinsame Unabhängigkeitsgruppe. Widersprüche (gleiches Thema, andere Zahlen, andere Quellen) → „umstritten“, höchstens 🟡, Skript nennt beide Seiten. `factcheck.json` ohne Quelltexte. |
| Stile | Diskussion, Interview, Debatte, Erzählung, „Erklär es mir wie 12“, Mythos-Check; Hinweis für Apple-Stimmen (kurze Sätze, keine Füllwörter). |
| Folge-Episoden | Nachfrage aus vorhandener Mappe (keine neue Recherche, ~5–8 Anfragen); „Tiefer eintauchen“ je Kapitel (neue Recherche, Nerd-Level +1). |
| Sonstiges | Benachrichtigungen (Erlaubnis erst beim ersten echten Lauf), Statistik je Episode, Bibliothekssuche, MP3-Export mit Kapiteln, Stimmen-Einrichtung öffnet Systemeinstellungen, Test-Set 5.8 (30 Mythen + 30 Fakten, DE/EN). |
| Reddit | entfernt (API nur auf Antrag). |

## Bekannte Grenzen
- Zahlenabgleich rechnet keine Einheiten um (m/s ↔ km/s, °C ↔ K). Eine korrekte, umgerechnete
  Aussage kann rot werden (im Test-Set gefunden). Lösung später: Einheiten-Normalisierung.
- Systemeinstellungs-Links sind nicht dokumentiert; Fallback öffnet die Bedienungshilfen.
- Neue Funktionen sind nur offline getestet; Live-Prüfung (Nachfrage, Neu-Schreiben, Test-Set mit
  Gemini) steht aus.
