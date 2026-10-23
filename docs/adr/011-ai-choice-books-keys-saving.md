# ADR-011: KI-Wahl pro Aufgabe, Bücher, Restzeit, Keys, Speichern, Einstellungen

- Status: angenommen
- Datum: 2026-10-03

## Quellen: Bücher statt Anna's Archive
Anna's Archive ist eine Schattenbibliothek (LibGen/Z-Library/Sci-Hub-Kopien); Volltexte von dort
wären Urheberrechtsverletzung. Stattdessen legale Volltexte:
- **Project Gutenberg** (gemeinfrei): offizielle OPDS-Suche, Text unter `/cache/epub/<id>/pg<id>.txt`,
  Gutenberg-Kopf/-Fuß entfernt. Gutendex war nicht erreichbar, deshalb OPDS; unscharfe Treffer
  ohne Suchbegriff in Titel/Autor werden verworfen.
- **Open Library / Internet Archive**: nur `ebook_access == public`; OCR-Text unter
  `archive.org/download/<ia>/<ia>_djvu.txt`.
- Pro Buch nur die 60 relevantesten Abschnitte; Bücher Stufe B mit Hinweis „oft alt“ bzw. „OCR“.
  Bei „Geschichte“ voreingestellt, sonst einzeln zuschaltbar. Live: Darwin (Gutenberg) und ein
  Open-Library-Scan je 60 Abschnitte.

## KI pro Aufgabe
Rollen `research` (Plan, Aussagen), `writer` (Gliederung, Skript, Neu-Schreiben), `verifier`, dazu
Sprachausgabe. `AIChoice` global (Einstellungen → KI) und optional pro Episode (`aiOverride`,
„KI für diese Folge“), gespeichert mit der Episode und genutzt für Recherche, Fortsetzen,
Skript, Nachfragen, Neu-Schreiben und Vertonung. Jede Rolle mit Ausweichkette bis Apple.

## Restzeit
`RemainingTimeEstimator`: lineare Hochrechnung aus dem Fortschritt der Phase (geglättet, erst ab
8 % und 4 s). Phasen: Quellen, Aussagen, Prüfen, Skript (inkl. Prüfung), Vertonen. Anzeige im
Fortschritt, im Episodenkopf und im Menüleisten-Icon; Skript zeigt „Kapitel x von n“.

## API-Keys
Pro Key „Testen“ (ein billiger Abruf beim Anbieter; OpenRouter zeigt Rest-Kontingent) und
„Key erstellen ↗“. Speicherort wählbar: Schlüsselbund (Standard, verschlüsselt) oder App-Datei
`keys.json` (0600, unverschlüsselt, keine Abfragen); beim Umschalten werden Keys übertragen und am
alten Ort gelöscht.

## Speichern & Einstellungen
Unter dem Player: „Audio speichern …“ (M4A/MP3 mit Kapiteln), „Transkript speichern …“
(txt/md/vtt), „Alles speichern …“ (Ordner mit Audio, Transkripten, Shownotes, Faktencheck).
Einstellungen zusätzlich als Seitenleisten-Eintrag, Zahnrad in der Werkzeugleiste und im
Menüleisten-Icon (⌘, bleibt).
