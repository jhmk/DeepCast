# DeepCast project overview

DeepCast is a personal macOS prototype for generating sourced podcast episodes from a topic or question.

## Pipeline

1. Plan research questions and source strategy
2. Fetch and normalize sources
3. Extract claims with source references
4. Run deterministic and LLM-assisted fact checks
5. Pause for review before script generation
6. Generate a structured multi-speaker script
7. Re-check factual segments against the claim map
8. Render speech and post-process audio
9. Export audio, transcript, chapters and shownotes

## Design principles

- Evidence first, script second
- Every factual segment should link back to claims and sources
- Human review is part of the workflow
- API keys belong in Keychain or untracked local config
- Generated audio and episode artifacts are not part of the repository
- The app is a prototype and not a medical, legal or journalistic product
