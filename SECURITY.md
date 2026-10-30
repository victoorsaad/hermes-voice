# Privacy and security

## What stays on your Mac

- Audio (dictation and calls) and transcription: always local (Core ML models from Hugging Face, downloaded once).
- Polishing with the **local** engine: llama.cpp on `127.0.0.1`.
- Config, history, recordings and voice profiles (speaker embeddings) in `~/Library/Application Support/Hermes`.
  With iCloud sync turned on (off by default), history, dictation audio, modes, vocabulary and voice profiles go to
  your iCloud Drive.

## What leaves your Mac, and only when you turn it on

| Feature | What is sent | Where |
|---|---|---|
| Call summary / live call chat | The call transcript (and, for Markdown folders, the list of note names in that folder so the summary can link them) | Claude, through your local Claude Code (`claude -p`, no tools, no session saved) |
| Polish with Claude | The dictated text (and selected text, for commands) | Claude, same as above |
| Markdown folder + git push | That note only (`git add/commit -- <note>`), never the rest of the repo | Your git remote |
| Notion | Title, summary and full transcript of the call | The Notion database you configure |
| Slack | Title, length, participants and summary (no transcript) | The webhook/channel you configure |

## Secrets

- Notion and Slack tokens are stored in the macOS Keychain (service `<bundle id>.tokens`), never in `config.json`
  or the repository.

## Recording consent

Recording calls may require the consent of everyone in the call where you live or work. That is your responsibility.

## Reporting

Please open a private security advisory on the GitHub repository rather than a public issue.
