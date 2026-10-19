// The one piece of the app that touches the radio: CoreBluetooth in, InklessKit's packets out.
// The job's phases come from InklessKit.FlowRule; this file only moves bytes and waits on the radio.
import Foundation
import CoreBluetooth
import InklessKit

@MainActor
final class PrinterLink: NSObject, ObservableObject {
    enum State: Equatable {
        case bluetoothOff, unavailable, looking, connecting, connected
        case printing(Int, Int)
        case notReady(UInt8)      // the printer refused the start: paper, lid
        case noAnswer             // the printer never acknowledged the start
        case unconfirmed          // rows sent, no "done" within 60 s — check the slip
        case printed, asleep
    }
    @Published var state: State = .looking
    @Published var firmware = ""
    @Published var battery: Int?
    @Published var temperature: Int?
    @Published var lastError = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var data: CBCharacteristic?
    private var lookTimer: Task<Void, Never>?

    // One print at a time. The waits below are resumed by delegate callbacks, never by timers,
    // except the two give-up timeouts (start 5 s, done 60 s).
    private var phase: FlowRule.Phase = .finished
    private var paused = false
    private var jobActive = false
    private var startWait: CheckedContinuation<UInt8, Never>?     // 0 = go · status ≠ 0 · 0xFE timeout · 0xFD link dropped
    private var doneWait: CheckedContinuation<Bool, Never>?
    private var resumeWait: CheckedContinuation<Void, Never>?
    private var radioWait: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isConnected: Bool {
        switch state { case .connected, .printed, .unconfirmed, .notReady, .noAnswer: return peripheral != nil; default: return false }
    }

    func look() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        state = .looking
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        lookTimer?.cancel()
        lookTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.peripheral == nil else { return }
            self.central.stopScan(); self.state = .asleep
        }
    }

    /// Density + start on AE01, wait for the ack, rows on AE03 as the radio allows, finalize, wait for done.
    func print(_ bitmap: Bitmap, darkness: Int) async {
        guard let p = peripheral, let control, let data, isConnected, !jobActive else { return }
        let job = PrintJob(bitmap: bitmap, darkness: darkness)
        jobActive = true; defer { jobActive = false }
        phase = .waitingForStart; paused = false
        state = .printing(0, job.chunks.count)
        for packet in job.preamble { p.writeValue(packet, for: control, type: .withoutResponse) }

        let startTimeout = Task { try? await Task.sleep(for: .seconds(5)); await self.finishStart(0xFE) }
        let status = await withCheckedContinuation { startWait = $0 }
        startTimeout.cancel()
        switch status {
        case 0: break
        case 0xFD: return                                   // the link dropped; dropped() already set the state
        case 0xFE: state = .noAnswer; phase = .finished; return
        default: state = .notReady(status); phase = .finished; return
        }

        let chunkLimit = min(MXW01.chunkSize, max(20, p.maximumWriteValueLength(for: .withoutResponse)))
        let chunks = job.chunks(size: chunkLimit)
        for (i, chunk) in chunks.enumerated() {
            if paused { await withCheckedContinuation { resumeWait = $0 } }            // the printer's back-pressure
            if !p.canSendWriteWithoutResponse { await withCheckedContinuation { radioWait = $0 } }   // the radio's
            guard peripheral != nil else { return }
            p.writeValue(chunk, for: data, type: .withoutResponse)
            state = .printing(i + 1, chunks.count)
        }
        phase = .waitingForDone
        p.writeValue(job.trailer, for: control, type: .withoutResponse)

        let doneTimeout = Task { try? await Task.sleep(for: .seconds(60)); await self.finishDone(false) }
        let confirmed = await withCheckedContinuation { doneWait = $0 }
        doneTimeout.cancel()
        guard peripheral != nil else { return }
        phase = .finished
        if !confirmed { state = .unconfirmed; return }
        try? await Task.sleep(for: .seconds(2))   // the printer keeps feeding after AA; an early disconnect truncates
        if peripheral != nil { state = .printed }
    }

    private func finishStart(_ status: UInt8) { startWait?.resume(returning: status); startWait = nil }
    private func finishDone(_ ok: Bool) { doneWait?.resume(returning: ok); doneWait = nil }

    private func handle(_ n: MXW01.Notification) {
        let before = phase
        phase = FlowRule.next(phase, on: n, paused: &paused)
        if before == .waitingForStart, phase == .streaming { finishStart(0) }
        if case .notReady(let s) = phase, before == .waitingForStart { finishStart(s) }
        if before == .waitingForDone, phase == .finished { finishDone(true) }
        if case .resume = n { resumeWait?.resume(); resumeWait = nil }
        switch n {
        case .firmware(let f): firmware = f
        case .status(_, let b, let t, _, _): battery = Int(b); temperature = Int(t)
        case .wantsStatusPoll:
            Task { try? await Task.sleep(for: .milliseconds(700)); if let control { peripheral?.writeValue(MXW01.statusPoll, for: control, type: .withoutResponse) } }
        default: break
        }
    }

    private func dropped() {
        if jobActive { lastError = "the link dropped mid-print — check the slip" }
        peripheral = nil; control = nil; data = nil; paused = false; phase = .finished
        finishStart(0xFD); finishDone(false)
        resumeWait?.resume(); resumeWait = nil
        radioWait?.resume(); radioWait = nil
        look()
    }
}

extension PrintJob {
    func chunks(size: Int) -> [Data] {
        let all = MXW01.raster(rows)
        return stride(from: 0, to: all.count, by: size).map { all.subdata(in: $0..<min($0 + size, all.count)) }
    }
}

extension PrinterLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            switch c.state {
            case .poweredOn: look()
            case .poweredOff: state = .bluetoothOff
            case .unsupported, .unauthorized: state = .unavailable
            default: break
            }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard name == "JK01" || services.contains(where: { $0.uuidString == MXW01.serviceUUID }) else { return }
        Task { @MainActor in
            guard peripheral == nil else { return }
            lookTimer?.cancel(); c.stopScan()
            peripheral = p; p.delegate = self; state = .connecting
            c.connect(p)
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([CBUUID(string: MXW01.serviceUUID)])
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in lastError = error?.localizedDescription ?? "connect failed"; dropped() }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in dropped() }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid.uuidString == MXW01.serviceUUID }) else { return }
        p.discoverCharacteristics(nil, for: s)
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let chars = s.characteristics ?? []
        Task { @MainActor in
            for ch in chars {
                switch ch.uuid.uuidString {
                case MXW01.controlUUID: control = ch
                case MXW01.dataUUID: data = ch
                case MXW01.notifyUUID, MXW01.notify2UUID: p.setNotifyValue(true, for: ch)
                default: break
                }
            }
            guard let control else { lastError = "no AE01 on this device"; central.cancelPeripheralConnection(p); return }
            try? await Task.sleep(for: .milliseconds(200))
            p.writeValue(MXW01.connectInit, for: control, type: .withoutResponse)
            try? await Task.sleep(for: .milliseconds(400))
            p.writeValue(MXW01.getSerial, for: control, type: .withoutResponse)
            lastError = ""
            state = .connected
        }
    }
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        Task { @MainActor in radioWait?.resume(); radioWait = nil }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        Task { @MainActor in handle(MXW01.parse(v)) }
    }
}
