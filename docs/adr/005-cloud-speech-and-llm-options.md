# ADR-005: Fish Audio (Standard-Stimmen) und OpenRouter (optionales LLM)

- Status: angenommen
- Datum: 2026-10-03

## Kontext
Mit Apple-Stimmen gibt es nur zwei gute deutsche Stimmen (Anna Premium, Martin
Erweitert). Für 3–4 Sprecher und natürlicheren Klang soll eine kostenlose Cloud-Stimme
genutzt werden. Für die Recherche soll neben Apple Intelligence (8k Kontext) ein größeres
Gratis-Modell testbar sein.

## Entscheidung Sprachausgabe
- **Fish Audio `s2.1-pro-free` ist Standard**, Apple ist automatischer Fallback.
  Globaler Schalter (Einstellungen → Stimmen: "Fish Audio (Apple als Fallback)" / "Nur
  Apple") plus Anbieter, Fish-Stimme und Apple-Fallback-Stimme pro Persona.
- `SpeechRenderer` (actor): versucht Fish, fällt bei Fehlern auf Apple zurück. Dauerhafte
  Fehler (kein Key, 401, 402 "Gratis beendet") schalten Fish für den Rest des Laufs ab,
  damit nicht jedes Segment erneut wartet. 429/5xx: 3 Versuche mit Backoff.
- Höchstens 3 parallele Fish-Anfragen (Limit Gratis-Tarif: 5).
- Cache pro Segment: SHA-256 aus Anbieter, Stimmen-ID, Modell, Text.
- Fallbacks werden in der Episode und den Shownotes vermerkt.
- Standardstimmen der Personas: generische Community-Stimmen, **keine Klone realer
  Personen**. Nur eine deutsche Stimme ist "licensed". Im Persona-Editor gibt es Suche,
  Hörproben und Filter "Nur lizenzierte".

### Messwerte (Live-Test 2026-10-03, Beispielskript 9 Segmente, 3 Sprecher)
| Wert | Ergebnis |
|---|---|
| Vertonung | 26 s für 54 s Audio (3 parallel) |
| Einzelsatz | 4–7 s Latenz |
| Lautheit Endprodukt | −16,2 LUFS integriert, LRA 3,1 LU |
| Kapitel | korrekt im M4A |
| Fallback bei ungültiger Stimme | funktioniert (Apple) |

## Audio-Kette
Jedes Segment → 44,1 kHz mono PCM (Fish liefert MP3 44,1 kHz, Apple CAF 22,05 kHz) →
Pausen (0,25 s gleicher Sprecher, 0,4 s Sprecherwechsel, 1,0 s Kapitelwechsel) →
zweistufiges `loudnorm` (−16 LUFS, −1,5 dBTP, linear) → AAC 96 kbit/s mono in M4A mit
Kapiteln und Metadaten, `+faststart`. Dazu `transcript.vtt` (WebVTT mit Sprecher-Tags,
nutzbar für `podcast:transcript`), `transcript.md`, `shownotes.md`.

## Entscheidung LLM (für Schritt 3)
- Baustein `OpenAICompatibleLLMProvider` für OpenRouter (später auch Ollama/LM Studio).
- Test 2026-10-03: `qwen/qwen3.8-27b:free` funktioniert (JSON, wörtliche Belege, findet
  Zahlen, die Apple Intelligence übersah). `google/gemma-4-*:free` wird durch die
  Konto-Einstellung "Zero Data Retention" blockiert – bewusst nicht geändert.
- Limit: 50 Anfragen/Tag im Gratis-Tarif → Pipeline muss mit wenigen, großen Anfragen
  arbeiten.

## Keys
Schlüsselbund, Dienst `local.deepcast`, Konten `fish-audio` und `openrouter`. Eingabe auch
in Einstellungen → API-Keys. Wegen der Ad-hoc-Signatur fragt macOS nach einem Neu-Build
evtl. erneut nach dem Zugriff ("Immer erlauben").

## Folgen
- Das Gratisangebot von Fish endet laut Anbieter am 30.11.2026. Danach greift der
  Apple-Fallback automatisch (402), oder der Schalter wird auf "Nur Apple" gestellt.
- Texte gehen an Fish Audio bzw. OpenRouter und dürfen dort teilweise zum Training
  verwendet werden. Für eine private App mit öffentlichen Rechercheinhalten akzeptiert.
