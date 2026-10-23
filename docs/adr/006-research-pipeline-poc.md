# ADR-006: Recherche-Pipeline im PoC und Ergebnis des ersten Probelaufs

- Status: angenommen
- Datum: 2026-10-03

## Entscheidung
- `LocalPipeline` (Swift) hinter `EngineClient`, zwei Phasen mit Review-Pause dazwischen:
  1. `research`: Plan → Wikipedia + DuckDuckGo → Seiten abrufen und Text extrahieren →
     Abschnitte (≈220 Wörter) → Aussagen mit wörtlichem Zitat → Duplikate zusammenführen →
     Zahlenabgleich im Code → unabhängiger Prüfer → Ampel nach `FactCheckRules`.
  2. `writeScript` (nach Freigabe): Gliederung → Skript kapitelweise (closed book) →
     `ScriptChecker` → bis zu 2 Umschreib-Runden → nicht reparierbare Beiträge entfernen.
- Ausgabe-Typen einmal mit `@Generable` deklariert. Für OpenRouter wird daraus per
  `GenerationSchema` (Codable) ein striktes JSON-Schema erzeugt, die Antwort per Codable
  dekodiert. Ein Typ für beide Modell-Welten.
- `LLMRouter`: Ketten pro Rolle. Schreiber: Qwen3.8 27B → Apple Intelligence. Prüfer:
  Gemma 4 31B → Qwen → Apple. Dauerhafte Fehler (Key, Tageslimit, gesperrt) schalten ein
  Modell für den Lauf ab; nach 2 vorübergehenden Fehlern in Folge ebenfalls.
- Qwen ohne "reasoning" für Extraktion/Skript (3× schneller), mit "reasoning" als Prüfer.
- Vertrauensstufen per Domain-Liste (`SourceTrust`), Unabhängigkeit per registrierbarer
  Domain; de/en-Wikipedia zählt als eine Quelle.
- Alle Zwischenstände als JSON im Episoden-Ordner (`plan.json`, `dossier.json`,
  `outline.json`, `script.json`), dazu `factcheck.md`.

## Probelauf "Wie funktionieren Tardigraden?" (5 min, 3 Sprecher, Standard)
| Wert | Ergebnis |
|---|---|
| Quellen | 6 gelesen: 4× Stufe A (nature.com, springer.com ×2, plos.org), 2× Wikipedia; 2 Seiten mit HTTP 403 (wiley, sciencedirect) übersprungen |
| Aussagen | 47, davon 🟢 26, 🟡 21, 🔴 0; Prüfer: 32 belegt, 14 teilweise |
| Prüfer | **Gemma war durchgehend überlastet** (gemeinsamer Google-Pool) → Qwen hat sich selbst geprüft |
| Recherche-Dauer | 4:27 min (davon ~3 min Prüfung) |
| Skript-Dauer | 40–75 s |
| Länge | v1: 3:10 (zu kurz), v2: 10:58 (zu lang, Wiederholungen), **v3: 5:57** |
| Lautheit | −16,1 LUFS |
| Gratis-Anfragen | ≈ 20 pro vollständiger Folge; das Tageslimit (50) war nach 1 Folge + 2 Skript-Neuläufen + Tests erreicht |

### Gefundene und behobene Fehler
- **Erfundene Zahl rutschte durch** ("nach zwei Jahren"), weil die Skript-Prüfung nur
  Ziffern kannte und das Modell Zahlen ausschreibt. → Deutsche/englische Zahlwörter
  (auch zusammengesetzt, "dreihundertfünfzig"); kleine Zahlen zählen, wenn eine Einheit
  folgt ("zwei Jahre", "drei Arten").
- Sprechernamen im Text ("Max: …") wären vorgelesen worden → werden entfernt.
- Länge: "mindestens N Wörter" führte zu Auffüllen und Wiederholungen → "etwa N,
  höchstens 1,25 N", mehr Kapitel, Wiederholungsverbot.
- "Das ist Konsens in der Forschung" ohne Beleg → Konsens-Behauptung nur mit grüner
  Konsens-Aussage.
- "Stell dir vor" für eine echte Studie → nur noch für erfundene Beispiele.

### Bekannte Schwächen
- Viele 🟡, weil Definitionen oft nur in Wikipedia stehen (eine B-Quelle) → häufiges
  "laut einer Quelle". Regel bleibt laut Spec; ggf. später Definitionen anders behandeln.
- Gemma als unabhängiger Prüfer praktisch nicht nutzbar, solange der gemeinsame
  Gratis-Pool überlastet ist. Optionen: eigener Google-AI-Studio-Key bei OpenRouter
  (BYOK) oder 10 $ Guthaben (1.000 Gratis-Anfragen/Tag).
- Qwen prüft sich selbst eher wohlwollend (0 × rot). Der Zahlenabgleich im Code ist
  deshalb der wichtigste Schutz.
