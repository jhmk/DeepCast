# ADR-010: Paywall-Abruf, eigene Quellen, Zitat- und Einheitenprüfung, natürlicher Dialog

- Status: angenommen
- Datum: 2026-10-03

## Paywall-Abruf (opt-in, Einstellungen → Quellen)
**Waterfox-Test (2026-10-03, Waterfox 6.7.5 / Gecko 153.4, geckodriver 0.37.1, BPC 4.4.5.6):**
- Steuerung per geckodriver funktioniert headless, Start ~2 s.
- Bypass Paywalls Clean wirkt auf Spiegel/Tagesspiegel, holt den Volltext dort aber von
  **archive.is**. Dafür verlangt Firefox die neue „fetch consent“-Einwilligung der Erweiterung.
  In einem frischen Profil fehlt sie; automatisch setzen ließ sie sich nicht (Neuladen der
  Erweiterung beendet die WebDriver-Sitzung, Speicher vor der Installation nicht beschreibbar).
- Ergebnis ohne Einwilligung: nur Anrisstext (50–190 Wörter).

**Entscheidung (Option 3 „beides“):**
1. **archive.is direkt** (`ArchiveFetcher`): neuester vorhandener Schnappschuss
   (`archive.is/newest/<url>`), kein Browser, keine neuen Schnappschüsse. Live: 4/4 Artikel
   (Spiegel+, Tagesspiegel) mit 812–3.070 Wörtern statt 50–190.
2. **Waterfox mit dauerhaftem DeepCast-Profil** (`WaterfoxSession`, W3C WebDriver direkt aus
   Swift, headless, `-profile`): Ausweichweg, wenn kein Schnappschuss existiert oder die Seite
   anders gelöst wird. Einmalige Einrichtung durch den Nutzer („Profil einrichten …“: eigenes
   Waterfox-Fenster mit `-no-remote`, BPC installieren, „opt-in“ für fetch aktivieren).
- Greift nur bei erkannter Paywall (`isAccessibleForFree:false`) oder zu wenig Text, max. 3
  Artikel pro Folge. Fehler → Quelle übersprungen. `SourceDocument.fetchMethod` vermerkt den
  Weg; Volltexte bleiben lokal, Shownotes/Bericht nur Link + kurze Belegstellen.

## Faktencheck
- **Einheiten** (`UnitConverter`): Länge, Geschwindigkeit, Temperatur (°C/K/°F), Masse, Zeit,
  Fläche, Volumen, Prozent → SI. Zahlenabgleich und Skript-Prüfung akzeptieren umgerechnete
  Werte (±5 %, Temperatur ±1,5 K) und vermerken „umgerechnet“.
- **Zitate** (`QuoteVerifier`): wörtlich nur, wenn der zitierte Wortlaut exakt im Abschnitt steht
  und die Person dort genannt ist; sonst „nur Paraphrase“. Das Skript darf Anführungszeichen nur
  mit geprüfter Zitat-Aussage und exaktem Wortlaut verwenden.
- **Crossref-Rückzugs-Check** für Paper mit DOI (`updated-by`, inkl. Retraction Watch):
  zurückgezogen → ausgeschlossen; Expression of Concern / Correction → Hinweis, Aussagen höchstens
  🟡. Live: Wakefield-Paper korrekt als zurückgezogen erkannt.

## Eigene Quellen
URLs (mit Paywall-Fallback), PDF (PDFKit), Text, Markdown, HTML per Drag & Drop, Feld oder
Dateiauswahl – in „Neue Episode“ und nachträglich im Review (nur diese Quelle wird extrahiert und
geprüft; bestehende Aussagen-IDs bleiben). Stufe pro Quelle wählbar (Standard C). Immer verwendet.

## Betrieb
- **Speicher:** Übersicht, Sprach-Cache leeren, Zwischenstände fertiger Folgen löschen (Audio,
  Transkript, Shownotes, Faktencheck, dossier.json bleiben), automatisches Limit 2 GB.
- **Modell-Prüfung** einmal täglich beim Start; fehlt ein gewähltes Gratis-Modell, Hinweis mit
  Ersatzvorschlag („Vorschlag übernehmen“). Ohne Liste eines Anbieters kein Urteil.

## Natürlicher Dialog (Option, Standard aus)
Aufeinanderfolgende Beiträge eines Kapitels (max. 12 bzw. 1.500 Zeichen) gehen als **eine**
Fish-Anfrage mit `<|speaker:i|>`-Tags und `reference_id`-Array. Satz-Zeitpunkte im Transkript
werden nach Textlänge geschätzt. Scheitert eine Gruppe, wird sie Satz für Satz vertont.
Live: 3 Sätze, 2 Sprecher → 11 s Audio in 6 s.
