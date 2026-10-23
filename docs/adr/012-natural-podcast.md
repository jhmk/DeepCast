# ADR-012: Natürlicher Podcast statt Faktenliste

- Status: angenommen
- Datum: 2026-10-05

## Problem (Rückmeldung zur ersten Folge)
Keine Struktur, Themensprünge, nichts erklärt, schlechte Übergaben, Wiederholungen (Aussagen und
Zitate), sehr oft „laut einer Quelle“, Stimmen klingen nach verschiedenen Räumen, unnatürlich –
„Fakten random zusammengeschmissen“.

**Ursachen:** Skript entstand von unten nach oben (Aussagen → Kapitel → jedes Kapitel einzeln mit
3 Sätzen Kontext), Beiträge Ø 16 Wörter, fast jeder ein Fakt; Code erlaubte Mehrfachnutzung von
Aussagen; Hedge-Pflicht bei jeder gelben Aussage (21/47 gelb, oft nur Wikipedia); Qwen 27B schwach
beim Dialog; Fish-Community-Stimmen aus verschiedenen Räumen, ±0,8 LU zwischen Segmenten.

## Vorbilder (vom Nutzer genannt, Transkripte ausgewertet)
| Podcast | Muster |
|---|---|
| Was bisher geschah | Erzähler (76 % der Worte) + Zuhörer; 2,1 Wechsel/min; Median 42 Wörter; 22 % kurze Reaktionen; Bogen vom Einstieg zum Thema, Bilder („muss man sich vorstellen“), Unsicherheit einmal konkret, Rückgriff am Ende |
| Überlebt | erzählt Geschichten (kein Transkript verfügbar) |
| Tim Gabel | Erklärketten, Wegweiser („hier wird es faszinierend“), Hörerreaktion vorwegnehmen, Fachbegriffe sofort erklären |
| Freak Show | Gespräch, 4,8 Wechsel/min, 33 % kurze Einwürfe |
| OMR | Einstieg mit überraschender konkreter Tatsache |

## Entscheidungen
1. **Podcast-Leitfaden** (Markdown, in der App bearbeitbar) wird mit jedem Plan-, Skript-,
   Review- und Überarbeitungs-Aufruf gesendet (kleine Modelle: Kurzfassung, eigene Regeln zuerst).
   „Rückmeldung zur Folge → in den Leitfaden übernehmen“: KI formuliert 1–4 Regeln, der Nutzer
   bestätigt. Faktenregeln bleiben im Code.
2. **Gesprächsformate**: Erzähler + Zuhörer (Standard), Erklärer + Fragende (Wissenschaftlich,
   Ratgeber, „wie 12“), Gespräch (Kurios, Debatte), Monolog – mit Zielwerten.
3. **Skript von oben nach unten**: Erzählplan (Aufhänger, Leitfrage, Kernerkenntnisse in
   Lernreihenfolge, Kapitel mit Erklärkette, Bild, Wegweiser; jede Aussage höchstens einem Kapitel
   zugeordnet) → ganzes Skript in einem Aufruf (bei langen Folgen Teile à ~2.500 Wörter mit vollem
   Plan und Ende des Vorherigen) → Messung + Testhörer (Verifier-Kette, unabhängiges Modell) →
   Überarbeitung, wenn nötig (bleibt nur, wenn nicht schlechter) → deterministische Faktenprüfung.
   Kleine Modelle (Apple): bisheriger kapitelweiser Weg mit Leitfaden; auch Fallback bei Fehlern.
4. **Qualitätsmessung** (`ScriptQuality`): Hauptstimmen-Anteil, Wechsel/min, kurze Reaktionen,
   Floskeln, mehrfach genutzte Aussagen, wiederholte 6-Wort-Phrasen, Themensprünge. Anzeige in der
   App (Skript-Qualität, Testhörer-Noten).
5. **Faktencheck im Skript**: jede Aussage und jedes Zitat nur einmal (Schluss darf zurückverweisen),
   „laut einer Quelle“ höchstens einmal, konkrete Herkunft zählt als Einschränkung, Unsicherheit einmal
   pro Quelle/Thema. Jede Aussage kommt mit Herkunftsbeschreibung ins Skript („Fachstudie in FEBS
   Journal, 2007“).
6. **Abweichung von Spec 5.4 (Nutzerentscheidung):** Im Standard-Modus genügt ein Nachschlagewerk
   (Wikipedia, Wikivoyage, Britannica) allein für **Definitionen und historische Daten** (grün).
   Zahlen, Ursachen usw. brauchen weiter eine zweite Quelle; „Streng“ unverändert.
7. **Skript-Modell**: `gemini-3.8-flash` (Google AI Studio, gratis) als Standard; Recherche bleibt
   bei einem frei wählbaren Anbieter. Private oder unternehmensinterne Gateways sind ausgeschlossen.
8. **Klang**: pro Segment Hochpass/Tiefpass, De-Esser, sanfter Kompressor, Lautheit −19 LUFS
   (Spanne zwischen Segmenten gemessen 1,6 → 1,0 LU); danach gemeinsamer Raum „Gespräch am Tisch“
   (frühe Reflexionen) oder „Trocken“; Pausen nach Situation (0,18 s nach kurzen Reaktionen, 0,55 s
   nach Fragen); „natürlicher Dialog“ (Fish, Kapitel am Stück) ist Standard. Gemessenes Sprechtempo
   fließt in die Längenplanung ein.

## Offen
Kein Live-Vergleich vorher/nachher (Nutzerentscheidung); Stimmen-Vorauswahl zurückgestellt.
Eine echte Folge mit dem neuen Weg steht aus.
