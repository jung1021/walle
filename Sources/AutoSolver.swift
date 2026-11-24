import SwiftUI

/// Continuous "solve on repeat" mode. Once started it watches the camera and,
/// whenever the view changes and then settles on a NEW scene, grabs a frame,
/// asks Claude, and speaks the answer — skipping blank scenes silently.
/// Stops when told, while the wake-word listener keeps running.
@MainActor
final class AutoSolver: ObservableObject {
    @Published var active = false
    @Published var statusLine = ""

    private weak var engine: CameraEngine?
    private weak var brain: Brain?
    private weak var speaker: Speaker?
    private weak var wakeWord: WakeWord?
    private var prompt = ""

    // Tunable: how different a frame must be to count as a new problem, and how
    // similar two scans must be to count as "settled" (robot stopped moving).
    private let newThreshold = 0.08
    private let stableThreshold = 0.05

    private var busy = false
    private var lastSolvedSig: [UInt8]?
    private var prevScanSig: [UInt8]?
    private var scanTimer: Timer?

    func configure(engine: CameraEngine, brain: Brain, speaker: Speaker,
                   wakeWord: WakeWord, prompt: String) {
        self.engine = engine
        self.brain = brain
        self.speaker = speaker
        self.wakeWord = wakeWord
        self.prompt = prompt
    }

    // MARK: - Commands

    func handleSolve() {
        active = true
        statusLine = "Auto-solving — say “Wall-E, stop” to end."
        lastSolvedSig = nil
        prevScanSig = nil
        engine?.captureCount = 0   // count captures for this auto-solve run
        startScanTimer()
        Task { await solveNow(force: true) }   // solve what's in view right now
    }

    func handleStop() {
        let wasActive = active
        active = false
        statusLine = ""
        scanTimer?.invalidate(); scanTimer = nil
        Task {
            if wasActive { await speaker?.speakAndWait("Okay, I'll stop.") }
            wakeWord?.resume()   // keep listening after stopping
        }
    }

    // MARK: - Scanning

    /// How often the auto-solver grabs a frame to check for a new problem.
    private let scanInterval: TimeInterval = 15

    private func startScanTimer() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scanTick() }
        }
    }

    private func scanTick() async {
        guard active, !busy, let engine else { return }
        guard let frame = await engine.captureSingleFrame(),
              let sig = ImageSignature.make(frame) else { return }
        let stable = prevScanSig.map { ImageSignature.difference($0, sig) < stableThreshold } ?? false
        let isNew = lastSolvedSig.map { ImageSignature.difference($0, sig) > newThreshold } ?? true
        prevScanSig = sig
        if stable && isNew && !busy {
            await solveNow(force: false)
        }
    }

    private func solveNow(force: Bool) async {
        guard let engine, let brain, let speaker, let wakeWord, !busy else { return }
        busy = true
        defer {
            busy = false
            wakeWord.resume()   // listening always comes back
        }

        wakeWord.pause()        // don't transcribe our own voice while solving
        await engine.ensurePlaying()
        guard let image = await engine.captureBestFrame() else {
            if force { await speaker.speakAndWait("I can't see the camera right now.") }
            return
        }
        lastSolvedSig = ImageSignature.make(image)

        let key = UserDefaults.standard.string(forKey: "claude_api_key") ?? ""
        let mdl = UserDefaults.standard.string(forKey: "claude_model") ?? "claude-sonnet-5-5"
        await brain.solve(image: image, apiKey: key, model: mdl, prompt: prompt)

        let answer = brain.answer
        let noProblem = answer.isEmpty || answer.lowercased().contains("no problem")
        if force {
            // First solve after the command always speaks (confirms it was heard).
            await speaker.speakAndWait(answer.isEmpty
                ? "Sorry, I couldn't get an answer. Try again."
                : answer)
        } else if !noProblem {
            await speaker.speakAndWait(answer)
        }
        // Auto-detected scene with no problem → stay silent.
    }
}
