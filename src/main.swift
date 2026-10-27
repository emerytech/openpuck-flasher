// OpenPuck Flasher — a personal macOS tool to flash the Couchside OpenPuck fork
// onto nRF52840 UF2-bootloader boards (nice!nano etc.) when fulfilling Etsy pucks.
//
// How flashing works: a board in its UF2 bootloader mounts as a mass-storage
// volume (/Volumes/NICENANO) with an INFO_UF2.TXT marker. Flashing = copy a
// verified .uf2 onto that volume; the board reboots itself as a Steam Controller
// Puck (USB 28de:1304) and the volume disappears. Same mechanism Couchside uses
// on the box — here it runs locally on the Mac.
//
// No third-party dependencies. Not sandboxed (needs /Volumes + network).

import SwiftUI
import AppKit
import CryptoKit

// App version — build.sh reads this line to stamp the bundle Info.plist, so the
// app, the DMG, and the Homebrew cask always report the same number.
let appVersion = "1.0.0"

// MARK: - Firmware pin (Couchside OpenPuck fork)

enum Firmware {
    static let pinnedTag = "0.9.40"
    static let pinnedName = "OpenPuck-0.9.40-standard.uf2"
    static let pinnedURL = URL(string:
        "https://github.com/emerytech/openpuck/releases/download/\(pinnedTag)/\(pinnedName)")!
    // sha256 of the pinned asset (same value Couchside verifies before writing).
    static let pinnedSHA256 = "ee2de6a415f87cacc2999893fd7803462a6d76f1ad4acbcd7962f0115575f478"
    static let minSize = 300_000
    static let maxSize = 4_000_000
    static let releasesAPI = URL(string:
        "https://api.github.com/repos/emerytech/openpuck/releases/latest")!
    // UF2 magic: first word 0x0A324655 ("UF2\n"), second word 0x9E5D5157,
    // little-endian on disk -> these 8 bytes.
    static let magic: [UInt8] = [0x55, 0x46, 0x32, 0x0A, 0x57, 0x51, 0x5D, 0x9E]
}

// UF2 bootloader volume labels for nRF52840 boards (nice!nano, generic, Feather).
let bootloaderLabels: Set<String> = ["NICENANO", "NRF52BOOT", "FTHR840BOOT"]

// MARK: - Errors

enum FlashError: LocalizedError {
    case size(Int)
    case magic
    case sha(String)
    case parse
    case noAsset
    case noFirmware
    case noBoard

    var errorDescription: String? {
        switch self {
        case .size(let n):  return "Firmware size \(n) is out of the expected range — download looks truncated or wrong."
        case .magic:        return "That file is not a UF2 image (bad magic)."
        case .sha(let g):   return "Checksum mismatch — refusing to flash. Got \(g.prefix(16))…"
        case .parse:        return "Could not parse the GitHub release response."
        case .noAsset:      return "No *-standard.uf2 asset found on the latest release."
        case .noFirmware:   return "No firmware file selected."
        case .noBoard:      return "No board in DFU mode."
        }
    }
}

// MARK: - Firmware source

enum FwMode: String, CaseIterable, Identifiable {
    case pinned = "Pinned 0.9.40"
    case latest = "Latest fork"
    case local  = "Local file"
    var id: String { rawValue }
}

// MARK: - Board state

enum BoardState: Equatable {
    case noBoard
    case boardReady(String)   // mounted bootloader volume path
    case flashing
    case puckPresent
    case error(String)
}

// MARK: - Engine

@MainActor
final class FlashEngine: ObservableObject {
    @Published var state: BoardState = .noBoard
    @Published var autoFlash = false
    @Published var flashedCount = 0
    @Published var busy = false
    @Published var mode: FwMode = .pinned
    @Published var localURL: URL?
    @Published var log: [String] = []

    private var armed = true            // one auto-flash per board-present episode
    private var lastFlashAt: Date?
    private var pollTimer: Timer?
    private let fm = FileManager.default
    private let tf: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var fwStatusText: String {
        switch mode {
        case .pinned: return "Pinned \(Firmware.pinnedName) · sha256 verified before every write"
        case .latest: return "Latest *-standard.uf2 from emerytech/openpuck (size + UF2 checked)"
        case .local:  return localURL?.lastPathComponent ?? "No file chosen"
        }
    }

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        logLine("Watching for a board in DFU…")
        poll()
    }

    func logLine(_ s: String) {
        log.append("\(tf.string(from: Date()))  \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // Detection: a bootloader volume present -> ready. Otherwise show "just
    // flashed" briefly after a success, else no board. (No USB scan needed — the
    // mounted volume is the authoritative flash target.)
    func poll() {
        if busy { return }
        if let vol = bootloaderVolume() {
            if case .boardReady = state {} else {
                state = .boardReady(vol)
                logLine("Board in DFU: \(vol)")
            }
            maybeAutoFlash(vol)
            return
        }
        armed = true
        if let f = lastFlashAt, Date().timeIntervalSince(f) < 10 {
            if state != .puckPresent { state = .puckPresent }
        } else if state != .noBoard {
            state = .noBoard
        }
    }

    func bootloaderVolume() -> String? {
        guard let vols = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return nil }
        for v in vols where bootloaderLabels.contains(v.uppercased()) {
            let p = "/Volumes/\(v)"
            if fm.fileExists(atPath: p + "/INFO_UF2.TXT") { return p }
        }
        return nil
    }

    private func maybeAutoFlash(_ vol: String) {
        guard autoFlash, armed, !busy else { return }
        armed = false
        Task { await flash(volume: vol, silent: true) }
    }

    func flashButtonTapped() {
        Task { await flash(volume: bootloaderVolume(), silent: false) }
    }

    func flash(volume: String?, silent: Bool) async {
        guard let vol = volume else { logLine("No board in DFU."); return }
        busy = true
        state = .flashing
        logLine(silent ? "Auto-flash: board detected." : "Flash requested.")
        do {
            let fw = try await resolveFirmware()
            logLine("Writing \(fw.lastPathComponent) → \(vol)")
            writeFirmware(fw, to: vol)
            let gone = await waitForVolumeGone(vol, timeout: 20)
            if gone {
                flashedCount += 1
                lastFlashAt = Date()
                state = .puckPresent
                logLine("✅ Flashed — board rebooting as a Steam Controller Puck. (session total: \(flashedCount))")
            } else {
                state = .error("Flash did not complete")
                logLine("⚠️ The board is still in DFU — the write may not have landed. Re-seat it and try again.")
            }
        } catch {
            state = .error(error.localizedDescription)
            logLine("❌ \(error.localizedDescription)")
        }
        busy = false
    }

    // MARK: Firmware resolution (download/verify/cache)

    private func resolveFirmware() async throws -> URL {
        switch mode {
        case .pinned:
            return try await fetchVerified(url: Firmware.pinnedURL, name: Firmware.pinnedName, sha: Firmware.pinnedSHA256)
        case .latest:
            let (url, name) = try await latestAsset()
            return try await fetchVerified(url: url, name: name, sha: nil)
        case .local:
            guard let u = localURL else { throw FlashError.noFirmware }
            let data = try Data(contentsOf: u)
            try verify(data, sha: nil)
            logLine("Local firmware verified (\(data.count) bytes, UF2 ok)")
            return u
        }
    }

    private func fetchVerified(url: URL, name: String, sha: String?) async throws -> URL {
        let dest = appSupportDir().appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path),
           let d = try? Data(contentsOf: dest),
           (try? verify(d, sha: sha)) != nil {
            logLine("Using cached \(name)")
            return dest
        }
        logLine("Downloading \(name)…")
        let data = try await get(url)
        try verify(data, sha: sha)
        try data.write(to: dest)
        logLine("Verified \(name) (\(data.count) bytes\(sha != nil ? ", sha256 ✓" : ", UF2 ✓"))")
        return dest
    }

    private func verify(_ data: Data, sha: String?) throws {
        guard data.count >= Firmware.minSize, data.count <= Firmware.maxSize else {
            throw FlashError.size(data.count)
        }
        guard [UInt8](data.prefix(8)) == Firmware.magic else { throw FlashError.magic }
        if let sha {
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got.lowercased() == sha.lowercased() else { throw FlashError.sha(got) }
        }
    }

    private func latestAsset() async throws -> (URL, String) {
        let data = try await get(Firmware.releasesAPI)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = obj["assets"] as? [[String: Any]] else { throw FlashError.parse }
        for a in assets {
            if let n = a["name"] as? String, n.hasSuffix("-standard.uf2"),
               let u = a["browser_download_url"] as? String, let url = URL(string: u) {
                return (url, n)
            }
        }
        throw FlashError.noAsset
    }

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("OpenPuck-Flasher", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    // Write the firmware onto the bootloader volume. The board reboots mid-write,
    // so the write call usually throws right at the end — that's EXPECTED and is
    // success; the real confirmation is the volume disappearing.
    private func writeFirmware(_ fw: URL, to vol: String) {
        let dest = URL(fileURLWithPath: vol).appendingPathComponent(fw.lastPathComponent)
        guard let data = try? Data(contentsOf: fw) else { logLine("Could not read firmware file."); return }
        do {
            try data.write(to: dest)
        } catch {
            logLine("(write ended early — board rebooted mid-write; confirming…)")
        }
    }

    private func waitForVolumeGone(_ vol: String, timeout: Double) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if !fm.fileExists(atPath: vol) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return !fm.fileExists(atPath: vol)
    }

    private func appSupportDir() -> URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OpenPuck Flasher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func chooseLocalFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose an OpenPuck .uf2 firmware file"
        if panel.runModal() == .OK, let u = panel.url {
            localURL = u
            mode = .local
            logLine("Selected local firmware: \(u.lastPathComponent)")
        }
    }
}

// MARK: - UI

struct StatusView: View {
    let state: BoardState

    private var icon: String {
        switch state {
        case .noBoard:     return "bolt.slash"
        case .boardReady:  return "memorychip"
        case .flashing:    return "arrow.down.circle"
        case .puckPresent: return "checkmark.seal.fill"
        case .error:       return "exclamationmark.triangle.fill"
        }
    }
    private var tint: Color {
        switch state {
        case .noBoard:     return .secondary
        case .boardReady:  return .accentColor
        case .flashing:    return .accentColor
        case .puckPresent: return .green
        case .error:       return .orange
        }
    }
    private var line: String {
        switch state {
        case .noBoard:
            return "No board. Plug in an nRF52840 and enter DFU — double-tap reset (or short RST–GND twice). A NICENANO drive appears here."
        case .boardReady(let v):
            return "Board ready in DFU (\((v as NSString).lastPathComponent)). Click Flash — or turn on Auto-flash."
        case .flashing:
            return "Flashing… writing firmware, do not unplug."
        case .puckPresent:
            return "Flashed — the board rebooted as a Steam Controller Puck. Unplug it and insert the next."
        case .error(let m):
            return m
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if case .flashing = state { ProgressView().controlSize(.large) }
                else { Image(systemName: icon).font(.system(size: 40)).foregroundStyle(tint) }
            }
            .frame(width: 56)
            Text(line).font(.title3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ContentView: View {
    @EnvironmentObject var e: FlashEngine

    private var canFlash: Bool {
        if e.busy { return false }
        if case .boardReady = e.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.accentColor)
                Text("OpenPuck Flasher").font(.title2).bold()
                Text("v\(appVersion)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Flashed this session: \(e.flashedCount)")
                    .font(.headline).foregroundStyle(.green)
            }

            StatusView(state: e.state)

            HStack(spacing: 12) {
                Button {
                    e.flashButtonTapped()
                } label: {
                    Label("Flash", systemImage: "bolt.fill").frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canFlash)
                .keyboardShortcut(.defaultAction)

                Toggle(isOn: $e.autoFlash) {
                    Label("Auto-flash (batch)", systemImage: "infinity")
                }
                .toggleStyle(.switch)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Firmware").font(.headline)
                Picker("", selection: $e.mode) {
                    ForEach(FwMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    Text(e.fwStatusText).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if e.mode == .local {
                        Button("Choose .uf2…") { e.chooseLocalFile() }
                    }
                }
            }

            Divider()

            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(e.log.enumerated()), id: \.offset) { idx, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: e.log.count) { _ in
                    if let last = e.log.indices.last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 600)
        .onAppear { e.start() }
    }
}

@main
struct OpenPuckFlasherApp: App {
    @StateObject private var engine = FlashEngine()
    var body: some Scene {
        WindowGroup("OpenPuck Flasher") {
            ContentView().environmentObject(engine)
        }
        .windowResizability(.contentMinSize)
    }
}
