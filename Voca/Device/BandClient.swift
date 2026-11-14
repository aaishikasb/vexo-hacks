import CoreBluetooth
import Foundation
import Observation

@MainActor @Observable final class BandClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private(set) var status = "Not connected"
    private(set) var info: BandProtocol.Info?
    private(set) var lastEvent = "No tap received"
    var onTap: ((UInt32, UInt8) -> Void)?
    var onAudio: ((Data, BandAudioTimeline.Packet) -> Void)?
    var onAudioGap: (() -> Void)?
    var onListeningEnded: ((String) -> Void)?
    private(set) var taps = BandTapHistory()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var assignedNumber: Int?
    private var sequence: UInt8 = 0
    private var linkGeneration = 0
    private var pending: Pending?
    private var scanTimeout: Task<Void, Never>?
    private var verified = false
    private var timeline = BandAudioTimeline()
    private var listening = false

    private struct Pending {
        let sequence: UInt8
        let opcode: UInt8
        let length: Int
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }

    /// Called only from an explicit Connect action after the bag number is entered.
    func connect(assignedNumber: Int) throws {
        guard (1...999).contains(assignedNumber) else { throw BandProtocol.Failure.identity }
        guard peripheral == nil, self.assignedNumber == nil else { throw BandProtocol.Failure.busy }
        linkGeneration += 1
        self.assignedNumber = assignedNumber
        taps = BandTapHistory()
        lastEvent = "No tap received"
        status = "Checking Bluetooth…"
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                disconnect(message: "Bluetooth unavailable. Enable Bluetooth, then reconnect.")
            }
            return
        }
        guard assignedNumber != nil, peripheral == nil else { return }
        status = "Looking for your assigned band…"
        central.scanForPeripherals(withServices: [CBUUID(string: BandProtocol.service)])
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.disconnect(message: "Band not found. Close the laptop dashboard, double-tap your band, then reconnect.")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, let number = assignedNumber, self.peripheral == nil,
              BandProtocol.matches(number: number,
                services: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString),
                name: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                manufacturer: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data) else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = "Connecting to band \(number)…"
        central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([CBUUID(string: BandProtocol.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        disconnect(message: "Connection failed. Double-tap your band and reconnect.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        disconnect(message: "Band disconnected. Listening stopped.")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: BandProtocol.service) }) else {
            disconnect(message: "Band service unavailable."); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: BandProtocol.rx), CBUUID(string: BandProtocol.tx)], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil else { disconnect(message: "Cannot read band characteristics."); return }
        rx = service.characteristics?.first { $0.uuid == CBUUID(string: BandProtocol.rx) && $0.properties.contains(.write) }
        tx = service.characteristics?.first { $0.uuid == CBUUID(string: BandProtocol.tx) && $0.properties.contains(.notify) }
        guard rx != nil, let tx else { disconnect(message: "Band transport is incompatible."); return }
        peripheral.setNotifyValue(true, for: tx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === tx else { return }
        guard error == nil, characteristic.isNotifying else { disconnect(message: "Cannot subscribe to band events."); return }
        let current = linkGeneration
        Task {
            do {
                let data = try await command(1, expectedLength: 16)
                guard let number = assignedNumber, peripheral === self.peripheral else { throw BandProtocol.Failure.disconnected }
                let verified = try BandProtocol.Info(data, assignedNumber: number)
                info = verified
                guard verified.supportsEvents else { throw BandProtocol.Failure.unsupported }
                let stopped = try await command(0x11, args: BandProtocol.mask(0xffff), expectedLength: 2)
                try BandProtocol.validateStreams(stopped, stopped: 0xffff)
                let started = try await command(0x10, args: BandProtocol.mask(2), expectedLength: 2)
                try BandProtocol.validateStreams(started, required: 2, stopped: 0x88)
                guard linkGeneration == current else { throw BandProtocol.Failure.disconnected }
                self.verified = true
                scanTimeout?.cancel()
                status = "Band \(number) connected · firmware \(verified.firmware)"
            } catch {
                if linkGeneration == current { disconnect(message: "Band verification failed. Reconnect to your assigned band.") }
            }
        }
    }
    private func command(_ opcode: UInt8, args: Data = Data(), expectedLength: Int) async throws -> Data {
        try Task.checkCancellation()
        guard pending == nil else { throw BandProtocol.Failure.busy }
        guard let peripheral, let rx, tx?.isNotifying == true else { throw BandProtocol.Failure.disconnected }
        let current = linkGeneration
        let seq = sequence
        sequence &+= 1
        let frame = Data([1, seq, opcode]) + args
        guard frame.count <= min(info?.maxFrame ?? 20, peripheral.maximumWriteValueLength(for: .withResponse)) else { throw BandProtocol.Failure.malformed }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, self?.pending?.sequence == seq else { return }
                    self?.disconnect(message: "Band command timed out. Reconnect before trying again.")
                }
                pending = Pending(sequence: seq, opcode: opcode, length: expectedLength, continuation: continuation, timeout: timeout)
                peripheral.writeValue(frame, for: rx, type: .withResponse)
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard self?.linkGeneration == current else { return }
            self?.disconnect(message: "Band operation cancelled.")
        } }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if peripheral === self.peripheral, characteristic === rx, error != nil {
            disconnect(message: "Band command failed. Reconnect before trying again.")
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === tx, error == nil, let data = characteristic.value,
              let frame = try? BandProtocol.parse(data, maxFrame: info?.maxFrame ?? 244) else { return }
        switch frame {
        case let .response(seq, opcode, status, data):
            guard let pending, BandProtocol.responseMatches(sequence: seq, opcode: opcode, status: status, dataCount: data.count,
                expectedSequence: pending.sequence, expectedOpcode: pending.opcode, expectedLength: pending.length) else { return }
            self.pending = nil
            pending.timeout.cancel()
            if status == 0 { pending.continuation.resume(returning: data) }
            else { pending.continuation.resume(throwing: BandProtocol.Failure.status(status)) }
        case let .event(time, code, _):
            guard info != nil, code == 1 || code == 2 else { return }
            lastEvent = "\(code == 1 ? "Single" : "Double") tap at band time \(time) ms"
            let fresh = taps.record(milliseconds: time, code: code, receivedAt: Date())
            if fresh { onTap?(time, code) }
        case let .audio(seq, opus):
            guard listening, let packet = timeline.accept(sequence: seq, receivedAt: Date()) else { return }
            if packet.missingPackets > 0 { onAudioGap?() }
            onAudio?(opus, packet)
        case let .notice(code, arg):
            if code == 3, arg == 3 { onAudioGap?() }
            if code == 2 {
                listening = false
                onAudioGap?()
                status = "Band battery critical. Listening stopped."
                onListeningEnded?(status)
            }
        case .unknown: break
        }
    }
    func startListening() async throws {
        guard verified else { throw BandProtocol.Failure.disconnected }
        guard info?.supportsAudio == true else { throw BandProtocol.Failure.unsupported }
        guard !listening else { return }
        timeline.restart(commandSentAt: Date(), micAlreadyOn: false)
        listening = true
        do {
            let response = try await command(0x10, args: BandProtocol.mask(8), expectedLength: 2)
            try BandProtocol.validateStreams(response, required: 8)
        }
        catch { disconnect(message: "Cannot start band listening. Reconnect and try again."); throw error }
    }
    func stopListening() async {
        listening = false
        guard peripheral != nil else { return }
        do {
            let response = try await command(0x11, args: BandProtocol.mask(0x88), expectedLength: 2)
            try BandProtocol.validateStreams(response, stopped: 0x88)
        }
        catch { disconnect(message: "Disconnected to stop the microphone.") }
    }
    func disconnect(message: String = "Not connected") {
        linkGeneration += 1
        central?.stopScan()
        scanTimeout?.cancel()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; rx = nil; tx = nil; info = nil; assignedNumber = nil
        listening = false; verified = false
        if let pending {
            self.pending = nil
            pending.timeout.cancel()
            pending.continuation.resume(throwing: BandProtocol.Failure.disconnected)
        }
        onAudioGap?()
        onListeningEnded?(message)
        status = message
    }
}
