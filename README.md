# Hermes

**English** · [Português](#português)

A macOS menu-bar voice app: local dictation and meeting notes. Speech-to-text runs on your Mac
([FluidAudio](https://github.com/FluidInference/FluidAudio): Parakeet + Cohere Transcribe on Core ML, speaker
diarization). [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude -p`, your own subscription) is only
used to summarize calls and, if you choose, to polish dictation.

- **Dictation**: hold **right ⌥**, speak, release; a quick tap toggles hands-free. Text streams while you talk and is
  pasted at the cursor.
- **Modes**: Prompt, Message, E-mail, Dictation, English and your own. Each one turns on per app or website and
  decides what the AI does with the text (polish, format, translate). Local LLM (llama.cpp) or Claude.
- **Selected text**: select text and dictate a command ("make it shorter", "translate to Spanish").
- **Calls** (⌥⌘R): records your mic and the Mac's audio, live transcript with a chat, separates and recognizes voices,
  and writes a note with summary, decisions and next steps.
- **Where call notes go** (Settings → Calls):
  - **Markdown folder** — any folder or an Obsidian vault. Optional `git commit` + `push` of that note only. Notes
    link to existing notes in the folder (`[[wiki links]]`).
  - **Notion** — a page in a database you choose.
  - **Slack** (optional, in addition) — posts the summary to a channel.
- **Claude Code**: notifications in the HUD when an agent finishes or asks for permission; answer by voice.

> The UI and the AI prompts are in Brazilian Portuguese today; transcription supports pt, en, es, fr, de, it.
> Translating the UI is a welcome contribution.

## Requirements

macOS 15+, Apple Silicon, Xcode (Swift 6 toolchain). Optional: `brew install llama.cpp ffmpeg` (local AI and any
audio format), Claude Code logged in (call summaries).

## Build

```sh
./scripts/bundle.sh          # builds ~/Library/Caches/Hermes-build/Hermes.app (ad-hoc signed)
./scripts/install.sh         # builds and replaces /Applications/Hermes.app
./scripts/release.sh 0.2.0 "notes"   # .dmg + tag + GitHub release on this clone's origin
```

| Variable | Default | Meaning |
|---|---|---|
| `HERMES_BUNDLE_ID` | `io.github.hermes-voice` | App bundle id (also prefixes the Claude Code hook notifications and the Keychain items). |
| `HERMES_SIGN_ID` | — (ad-hoc) | Signing identity. With a stable certificate macOS keeps mic/accessibility permissions between builds; with ad-hoc it may ask again after each build. |
| `HERMES_KEYCHAIN` | — | Keychain holding that certificate. |

On first launch Hermes downloads the transcription model (~2.2 GB) and, if llama.cpp is installed, a local LLM
(~2.5 GB). It asks for Microphone, Accessibility and System Audio Recording.

CLI helpers for testing: `Hermes transcribe <file>`, `process <dir> [--no-push] [--vault <path>] [--no-claude]`,
`polish <mode> "text"`, `numeros "text"`, `modelos`, `hooks on|off`.

## Configure Notion (beta)

Notion and Slack compile and follow the public APIs, but have not yet been exercised against a real workspace. Issues welcome.

1. Create an internal integration at <https://www.notion.so/my-integrations> and copy its token.
2. Create (or pick) a database for meeting notes and **share it with the integration** (⋯ → Connections).
3. Settings → Calls → Destination **Notion**: paste the token (Enter saves it to the Keychain) and the database link
   or id. Each call becomes a page titled with the call title; the body has the summary, decisions, next steps (as
   to-dos) and the transcript. Re-processing a call (refine, name speakers) archives the old page and creates a new one.

## Configure Slack (beta)

Settings → Slack → turn on, then either:
- an **Incoming Webhook** URL (simplest; the channel is fixed by the webhook), or
- a **bot token** (`xoxb-…`, scope `chat:write`, bot invited to the channel) plus the channel name or id.

Only new calls are posted (title, length, participants and the summary — not the transcript).

## Data

- `~/Library/Application Support/Hermes`: config, models, call recordings, history, modes, vocabulary, voice
  profiles, log. Optional iCloud Drive sync (off by default) moves history/modes/vocabulary/voices to
  `iCloud Drive/Hermes`.
- Tokens: macOS Keychain. See [SECURITY.md](SECURITY.md).

## License

MIT.

---

## Português

App de voz para a barra de menus do macOS: ditado e notas de reunião, com a transcrição rodando no próprio Mac. O
Claude Code (`claude -p`, com a sua assinatura) só entra no resumo das calls e, se você quiser, no polimento do ditado.

- **Ditado**: segure **⌥ direito**, fale e solte; um toque rápido liga o modo mãos livres.
- **Modos** por app/site (polir, formatar, traduzir), com IA local (llama.cpp) ou Claude.
- **Calls** (⌥⌘R): grava seu mic e o áudio do Mac, transcrição ao vivo com chat, reconhece as vozes e gera a nota.
- **Destino das notas** (Ajustes → Calls): **pasta de Markdown** (qualquer pasta ou vault do Obsidian, com commit +
  push opcional só da nota) ou **Notion** (página num banco). **Slack** é opcional e posta o resumo num canal.

Montagem: `./scripts/bundle.sh` (assinatura ad-hoc; use `HERMES_SIGN_ID` para um certificado fixo e o macOS manter as
permissões) e `./scripts/install.sh`. Notion: crie uma integração interna, compartilhe o banco com ela e cole token +
link do banco em Ajustes. Slack: webhook de entrada, ou token de bot (`chat:write`) + canal. Tokens ficam no Keychain.
