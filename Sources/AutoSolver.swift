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

    // Tunable (see ImageSignature.changeScore): how much the most-changed part
    // of the picture must differ from the last solved frame to count as a new
    // problem, and how alike two frames taken a moment apart must be to count
    // as "settled" (nothing moving, nobody mid-typing).
    private let newThreshold = 0.04
    private let stableThreshold = 0.04

    private var busy = false
    private var lastSolvedSig: [UInt8]?
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
        startScanTimer()
        // The wake word paused itself when it heard the command; turn it straight
        // back on so commands are still heard while Wall-E looks and thinks.
        wakeWord?.resume()
        guard !busy else { return }            // already working on one
        lastSolvedSig = nil
        engine?.captureCount = 0               // count captures for this run
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

    /// How often to grab a frame to check for a new problem — set in the app's
    /// Settings (UserDefaults key "auto_scan_interval"), defaulting to 15s.
    private var currentInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "auto_scan_interval")
        return v >= 1 ? v : 15
    }

    private func startScanTimer() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scanTick() }
        }
    }

    /// Re-arm the timer with the latest interval (call when the setting changes).
    func reloadInterval() {
        if active { startScanTimer() }
    }

    private func scanTick() async {
        guard active, !busy, let engine else { return }
        guard let frame = await engine.captureSingleFrame(),
              let sig = ImageSignature.make(frame) else {
            statusLine = "Auto-solving — couldn't grab a frame."
            return
        }
        // 1. Has anything changed since the frame we last solved?
        let change = lastSolvedSig.map { ImageSignature.changeScore($0, sig) } ?? 1.0
        guard change > newThreshold else {
            statusLine = String(format: "Auto-solving — same view (change %.0f%%, needs %.0f%%)",
                                change * 100, newThreshold * 100)
            return
        }
        // 2. Is the view holding still? Compare with a second frame a moment later.
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard active, !busy,
              let frame2 = await engine.captureSingleFrame(),
              let sig2 = ImageSignature.make(frame2) else { return }
        let motion = ImageSignature.changeScore(sig, sig2)
        guard motion < stableThreshold else {
            statusLine = String(format: "Auto-solving — view still moving (%.0f%%), waiting",
                                motion * 100)
            return
        }
        statusLine = String(format: "Auto-solving — new view (change %.0f%%), solving…", change * 100)
        await solveNow(force: false)
    }

    /// Speak with the mic off (so Wall-E doesn't transcribe itself), then listen again.
    private func say(_ text: String) async {
        guard let speaker, let wakeWord else { return }
        wakeWord.pause()
        await speaker.speakAndWait(text)
        wakeWord.resume()
    }

    private func solveNow(force: Bool) async {
        guard let engine, let brain, !busy else { return }
        busy = true
        defer { busy = false }

        // Listening stays ON while capturing and while Claude thinks, so
        // "Wall-E, stop" is heard. It is only off while Wall-E is talking.
        await engine.ensurePlaying()
        guard let image = await engine.captureBestFrame() else {
            if force { await say("I can't see the camera right now.") }
            return
        }
        // Baseline for "has it changed?" — taken through the same quick-scan
        // path the later comparisons use, so the two are like for like.
        if let base = await engine.captureSingleFrame() {
            lastSolvedSig = ImageSignature.make(base)
        } else {
            lastSolvedSig = ImageSignature.make(image)
        }

        let key = UserDefaults.standard.string(forKey: "claude_api_key") ?? ""
        let mdl = UserDefaults.standard.string(forKey: "claude_model") ?? "claude-sonnet-5-5"
        await brain.solve(image: image, apiKey: key, model: mdl, prompt: prompt)

        guard active else { return }           // told to stop while thinking: stay quiet

        let answer = brain.answer
        let noProblem = answer.isEmpty || answer.lowercased().contains("no problem")
        if !noProblem {
            // Claude confirmed there is a problem: announce it, then give the answer.
            await say("I see a problem to solve. " + answer)
        } else if force {
            // The first look after a command always answers, so you know it heard you.
            await say(answer.isEmpty ? "Sorry, I couldn't get an answer. Try again." : answer)
        }
        // A new view with no problem, found while scanning: stay silent.
        if active { statusLine = "Auto-solving — watching for a new problem." }
    }
}
