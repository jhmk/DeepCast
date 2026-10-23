# ADR-007: Neue Quellen, stabile Signatur, Google AI Studio

- Status: angenommen
- Datum: 2026-10-03

## 1. Schlüsselbund-Abfragen (stabile lokale Signatur)
**Problem:** Ad-hoc-signierte Apps haben als "Designated Requirement" nur ihren
Code-Hash. "Immer erlauben" im Schlüsselbund gilt deshalb nur für genau diesen Build;
jeder neue Build fragt erneut.

**Entscheidung:**
- Selbst erstelltes Code-Signing-Zertifikat "DeepCast Local Signing" (RSA 2048, 10 Jahre,
  EKU codeSigning) im Anmelde-Schlüsselbund. Keine Vertrauenseinstellung nötig.
  Designated Requirement jetzt: `identifier "local.deepcast.DeepCast" and certificate leaf = H"3d6f…"`
  – gleich für alle Builds.
- `project.yml`: `CODE_SIGN_IDENTITY = $(DEEPCAST_SIGN_IDENTITY)`, Standard
  "DeepCast Local Signing". Ohne Zertifikat: `DEEPCAST_SIGN_IDENTITY=- xcodebuild …`.
- Bestehende Keys wurden mit `-T <App>` neu angelegt, damit die App ohne Rückfrage lesen darf.
- `KeychainStore` liest jeden Key nur einmal pro App-Start (Speicher-Cache) und greift während
  Unit-Tests gar nicht auf den Schlüsselbund zu.

## 2. Quellen
| Quelle | Zugang | Stufe | Hinweise |
|---|---|---|---|
| Wissenschaftliche Paper | OpenAlex API (frei, kein Key, `mailto` für den "polite pool") | A (Journal) / B (Preprint) | Abstract immer, Volltext wenn Open Access (HTML oder PDF via PDFKit). Zurückgezogene Arbeiten gefiltert (`is_retracted`). Übersichtsarbeiten werden ab Nerd-Level 4 bevorzugt. Zwei Studien in derselben Zeitschrift gelten als unabhängig. |
| Podcast-Transkripte | iTunes Search API (frei) → RSS `podcast:transcript` (JSON/VTT/SRT/Text) oder lokaler Apple-Podcasts-Cache `transcript_<trackId>.ttml` | C | Kein Audio-Download, keine eigene Transkription. Lokaler Cache enthält nur Folgen, deren Transkript in der Podcasts-App auf diesem Mac geöffnet wurde. Apples Transkript-Server (privat, Token) wird nicht angesprochen. |

**Reddit: nicht umgesetzt.** Unauthentifizierte Zugriffe blockiert Reddit (getestet: HTTP 403),
neue API-Apps werden nur auf Antrag nach der "Responsible Builder Policy" freigegeben.
Ohne Zugang kein Reddit (Entscheidung des Nutzers, keine Testdaten).

Anzahl je Folge nach Nerd-Level: Paper 1/2/3 (≤2/3/≥4), Podcasts 2/1.
Alle Quellen pro Episode abschaltbar.

## 3. Google AI Studio (eigener Key)
Test 2026-10-03:
| Modell | Ergebnis |
|---|---|
| gemma-4-31b-it (direkt bei Google) | 1 von 5 Anfragen erfolgreich, Rest 500/503 "high demand" – gleiches Problem wie über OpenRouter |
| gemini-3.5-flash, gemini-flash-latest | 503 "high demand" |
| **gemini-3.8-flash** | 2/2 erfolgreich, ~5 s, strenge und korrekte Urteile (erkannte auch "Weltall" ≠ "zwei Wochen Weltraumvakuum") |
| gemini-3.5-flash-lite | 2/2, ~1 s, gut, aber milder (wertete obiges als "belegt") |

**Entscheidung:** Direkte Anbindung über Googles OpenAI-kompatible Schnittstelle
(`LLMEndpoint.googleAI`), kein Umweg über OpenRouter-BYOK nötig.
- Prüfer: **gemini-3.5-flash-lite** (Standard, Wunsch des Nutzers; gemini-3.8-flash ist strenger
  und in den Einstellungen wählbar), danach Schreib-Kette.
- Schreib-Kette: Qwen3.8 27B (OpenRouter) → gemini-3.5-flash-lite (Google, eigenes
  Kontingent) → Apple Intelligence. Damit läuft die App auch nach Erschöpfen des
  OpenRouter-Tageslimits weiter.
- Key im Schlüsselbund, Konto `google-ai`. Gratis-Tarif: Anfragen dürfen von Google zur
  Produktverbesserung genutzt werden.
