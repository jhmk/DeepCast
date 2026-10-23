# ADR-009: Episoden-Kategorien und Reise-Quellen

- Status: angenommen
- Datum: 2026-10-03

## Entscheidung
- **Kategorie** (Inhalt/Zweck) ergänzt den **Stil** (Form). 12 Kategorien: Allgemein, Einstieg ins
  Thema, Wissenschaftlich, Lebensnah, Reiseführer, Geschichte/Zeitreise, Aktuell/Nachrichten,
  Ratgeber/How-to, Porträt, Kurios & Fun Facts, Hintergrund & Analyse, Entspannt/Gute Nacht.
- Kategorien **stellen nur voreinstellen** (Nerd-Level, Ausschweifungen, Strenge, Stil, Quellen,
  Sprecher); alles bleibt im Formular änderbar. Faktencheck-Regeln gelten unverändert.
- Jede Kategorie liefert eine Anweisung für Planung, Gliederung und Skript (`{{category_instruction}}`)
  sowie ggf. einen Extraktions-Hinweis und zusätzliche Suchanfragen.
- **Entspannt / Gute Nacht:** Sprechtempo 0,9 (Fish `prosody.speed`, Apple `utterance.rate`),
  Pausen ×1,6. Eigener Cache-Eintrag pro Tempo.

## Reise-Quellen (Lesetest 2026-10-03)
| Quelle | Zugang | Stufe |
|---|---|---|
| Wikivoyage | MediaWiki-API wie Wikipedia (`WikipediaClient(site: "wikivoyage")`), kein Key | B |
| Lonely Planet, Merian, Marco Polo, DuMont, Baedeker, Fodor's, Frommer's, Rough Guides, Rick Steves, ADAC | Web-Abruf (Lonely Planet/Merian getestet: lesbar) | B |
| Auswärtiges Amt (Reise- und Sicherheitshinweise) | Web | A |
| Offizielle Tourismusseiten (visit…, …tourismus…, .travel, turismo…) | Web | C + Hinweis „Werbung“ |
| Reiseblogs, Atlas Obscura | Web | C; persönliche Tipps als Meinung/Erfahrung |
| GEO Reisen, reisereporter.de | blockieren (HTTP 403) | – |

Bei Reiseführern zusätzliche DuckDuckGo-Anfragen („<Ort> Reiseführer“, „… Reiseblog Tipps“,
„… offizielle Tourismus Seite“). Preise, Öffnungszeiten und Fahrpläne im Skript immer mit
„Stand <Jahr>, bitte vor Ort prüfen“. Wikivoyage ist nur bei der Kategorie Reiseführer
standardmäßig an.

## Nachtrag: mehrere Kategorien und Länge
- Bis zu **3 Kategorien** gleichzeitig (`CategoryMix`). Kombination: strengster Faktencheck,
  höchstes Nerd-Level und höchste Ausschweifung, Vereinigung der Quellen, Stil und Sprecher von
  der zuerst gewählten Kategorie (★), alle Anweisungen zusammen. Hinweise bei widersprüchlichen
  Paaren (z.B. Entspannt + Aktuell). Alte Episoden mit einer Kategorie werden übernommen.
- **Länge:** Schieberegler 10–60 min in 10-Minuten-Schritten (Standard 10). Kapitel skalieren
  mit (bis 14), Quellen bis 10. Nachfrage-Folgen bleiben 2–8 min.
- **Erwartete Dauer** aus der Wortzahl (DE 130, EN 150 Wörter/min) im Episodenkopf und im
  Skript-Editor, sobald ein Skript existiert; Wortzahl und Schätzung stehen auch in den Hinweisen.
- **Nachjustieren:** Weicht ein Kapitel um mehr als 30 % von seinem Wortbudget ab, wird es einmal
  mit Längen-Hinweis neu geschrieben; der nähere Entwurf gewinnt. Höchstens max(2, Kapitel/3)
  Zusatz-Anfragen pro Folge, um das Gratis-Kontingent zu schonen.
