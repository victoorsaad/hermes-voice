import Foundation

/// Usa o Claude Code instalado (`claude -p`), que roda com o login da assinatura do usuário.
enum Claude {
    static func run(prompt: String, input: String, claudePath: String, timeout: TimeInterval = 300) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: claudePath) else {
            throw HermesError("Claude Code não encontrado em \(claudePath)")
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claudePath)
                // Sem ferramentas: só texto entra, só texto sai.
                p.arguments = ["-p", prompt, "--output-format", "text", "--tools", "",
                               "--no-session-persistence", "--setting-sources", ""]
                p.currentDirectoryURL = Config.dir
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                p.environment = env
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                p.standardInput = stdin
                p.standardOutput = stdout
                p.standardError = stderr
                do { try p.run() } catch { cont.resume(throwing: error); return }

                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()

                let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus == 0, !text.isEmpty {
                    cont.resume(returning: text)
                } else {
                    let msg = String(decoding: err, as: UTF8.self).prefix(400)
                    cont.resume(throwing: HermesError("claude -p falhou (\(p.terminationStatus)): \(msg)"))
                }
            }
        }
    }

    static let liveCallPrompt = """
    Você acompanha uma call que está acontecendo agora, em nome de quem usa o Hermes. No stdin vem a transcrição até o momento \
    (feita ao vivo, pode ter erros; "Outros" são as pessoas do outro lado) e a pergunta da pessoa.
    Responda em português do Brasil, curto e direto (até 5 linhas ou uma lista curta), só com base na transcrição. \
    Cite o momento [mm:ss] quando ajudar. Se a resposta não estiver na transcrição, diga isso.
    """

    static let summaryPrompt = """
    Você recebe no stdin a transcrição de uma call (falantes identificados por nome ou "Pessoa N"). \
    Escreva em português do Brasil, em Markdown, SEM título de nível 1, exatamente nestas seções:
    ## Resumo
    (3–6 frases)
    ## Decisões
    (lista; "Nenhuma registrada" se não houver)
    ## Próximos passos
    (lista de tarefas "- [ ] responsável — tarefa", quando houver responsável claro)
    ## Pontos em aberto
    (lista curta)
    Depois das seções, para cada "Pessoa N", deduza o nome pelo conteúdo (alguém chama a pessoa pelo nome, \
    ela se apresenta, responde quando é chamada…). Escreva uma linha por pessoa que tiver indício razoável:
    FALANTE: Pessoa N = Nome | indício curto
    Omita quem não tiver indício. Nunca use o nome de quem já está identificado.
    Se vier uma lista "NOTAS DO VAULT" antes da transcrição, escreva uma linha \
    RELACIONADO: nota; nota (até 6) com as notas da lista sobre projetos, pessoas ou assuntos claramente tratados na call, \
    copiando o nome exatamente como está na lista; prefira a nota central do projeto (a nota-índice dele). Nas seções, pode marcar como [[nome]] só nomes que estão na lista.
    Na última linha escreva apenas: TITULO: <título curto da call, até 6 palavras>
    Não invente fatos que não estão na transcrição.
    """

    /// Só os links, para notas de call antigas (`Hermes relink`).
    static let relatedPrompt = """
    Você recebe no stdin uma lista "NOTAS DO VAULT" e depois a nota de uma call. \
    Responda só com uma linha: RELACIONADO: nota; nota (até 6), com as notas da lista sobre projetos, pessoas ou assuntos \
    claramente tratados na call, copiando o nome exatamente como está na lista. Prefira a nota central do projeto \
    (a nota-índice dele) a notas de detalhe. Se nenhuma servir: RELACIONADO:
    """

    static let polishPrompt = """
    Você recebe um texto ditado por voz. Devolva SÓ o texto corrigido: pontuação, \
    maiúsculas e erros óbvios de transcrição, mantendo idioma, palavras e tom. Sem comentários, sem aspas.
    Exemplo: "hoje eu fui no banco e depois passei na farmácia" → "Hoje eu fui no banco e depois passei na farmácia."
    """
}
