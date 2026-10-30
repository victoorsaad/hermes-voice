import Foundation

/// Modelos que não vêm com o FluidAudio: baixados do Hugging Face na 1ª abertura (outro Mac, instalação nova).
/// Parakeet e diarização o próprio FluidAudio baixa.
enum Models {
    struct File {
        let url: URL
        let destination: URL
        let size: Int64
    }

    private static let cohereRepo = "https://huggingface.co/FluidInference/cohere-transcribe-03-2026-coreml/resolve/main/"
    private static let cohereFiles: [(String, Int64)] = [
        ("vocab.json", 338_520),
        ("q8/cohere_encoder.mlmodelc/analytics/coremldata.bin", 243),
        ("q8/cohere_encoder.mlmodelc/coremldata.bin", 421),
        ("q8/cohere_encoder.mlmodelc/metadata.json", 2_587),
        ("q8/cohere_encoder.mlmodelc/model.mil", 2_444_649),
        ("q8/cohere_encoder.mlmodelc/weights/weight.bin", 1_881_964_672),
        ("q8/cohere_decoder_cache_external_v2.mlmodelc/analytics/coremldata.bin", 243),
        ("q8/cohere_decoder_cache_external_v2.mlmodelc/coremldata.bin", 1_562),
        ("q8/cohere_decoder_cache_external_v2.mlmodelc/metadata.json", 13_587),
        ("q8/cohere_decoder_cache_external_v2.mlmodelc/model.mil", 207_280),
        ("q8/cohere_decoder_cache_external_v2.mlmodelc/weights/weight.bin", 304_453_120),
    ]

    static var cohere: [File] {
        cohereFiles.map { path, size in
            File(url: URL(string: cohereRepo + path)!,
                 destination: Transcriber.cohereDir.appendingPathComponent(path.replacingOccurrences(of: "q8/", with: "")),
                 size: size)
        }
    }

    static var llm: [File] {
        [File(url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
              destination: LocalLLM.modelFile, size: 2_497_281_120)]
    }

    static func missing(_ files: [File]) -> [File] {
        files.filter { !FileManager.default.fileExists(atPath: $0.destination.path) }
    }

    /// Baixa o que falta, um arquivo por vez. `progress` recebe a fração (0–1) do total.
    static func download(_ files: [File], progress: @escaping @Sendable (Double) -> Void) async throws {
        let todo = missing(files)
        let total = Double(todo.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        for f in todo {
            try FileManager.default.createDirectory(at: f.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            let (tmp, response) = try await URLSession.shared.download(from: f.url, delegate: Progress { bytes in
                progress(total > 0 ? Double(base + bytes) / total : 1)
            })
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw HermesError("Download falhou: \(f.url.lastPathComponent)")
            }
            try? FileManager.default.removeItem(at: f.destination)
            try FileManager.default.moveItem(at: tmp, to: f.destination)
            done += f.size
            progress(total > 0 ? Double(done) / total : 1)
        }
    }

    private final class Progress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onBytes: (Int64) -> Void
        init(_ onBytes: @escaping (Int64) -> Void) { self.onBytes = onBytes }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            onBytes(totalBytesWritten)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    /// Programas do Homebrew que o Hermes usa, se estiverem instalados.
    static var missingTools: [String] {
        let has = { (name: String) in
            ["/opt/homebrew/bin/", "/usr/local/bin/"].contains { FileManager.default.isExecutableFile(atPath: $0 + name) }
        }
        return [("llama-server", "llama.cpp"), ("ffmpeg", "ffmpeg")].filter { !has($0.0) }.map(\.1)
    }
}
