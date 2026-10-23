# ADR-002: PoC-Pipeline in Swift hinter `EngineClient`

- Status: angenommen
- Datum: 2026-10-03

## Kontext
Die Spec sieht eine Python-Engine als Hintergrunddienst vor. Für den PoC gilt: keine
Python-Engine, keine Modell-Downloads, nur lokale Apple-Technik. Trotzdem soll die
Oberfläche später unverändert mit der Python-Engine funktionieren.

## Entscheidung
- Die App spricht nur mit dem Protocol `EngineClient` (Episode starten, Fortschritt als
  `AsyncStream`, Review-Freigabe, Abbrechen/Fortsetzen).
- Im PoC implementiert `LocalPipeline` dieses Protocol direkt in Swift:
  Apple Intelligence (ADR-003), DuckDuckGo + Wikipedia (ADR-004), AVSpeechSynthesizer,
  ffmpeg.
- Jede Stufe schreibt ihr Ergebnis als JSON in den Episoden-Ordner
  (`~/Music/DeepCast/<Datum Thema>/`), damit Läufe fortgesetzt werden können und die
  Formate später mit der Python-Engine geteilt werden.
- Die Pipeline pausiert nach dem Faktencheck (Review-Pause), Skript und Audio entstehen
  erst nach Freigabe.

## Folgen
- Ein Teil der Logik wird später nach Python portiert. Das wird bewusst in Kauf genommen,
  um die Idee schnell und kostenlos zu prüfen.
- Die JSON-Formate der Artefakte sind die eigentliche Schnittstelle und werden stabil
  gehalten.
