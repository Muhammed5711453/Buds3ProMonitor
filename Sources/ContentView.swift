import SwiftUI
import CoreBluetooth
import AVFoundation
import WidgetKit

// MARK: - BLE & Samsung Protocol Manager

final class BudsBLEManager: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var isScanning: Bool = false

    @Published var leftBattery: Int? = nil
    @Published var rightBattery: Int? = nil
    @Published var caseBattery: Int? = nil

    @Published var isLeftCharging: Bool = false
    @Published var isRightCharging: Bool = false
    @Published var isCaseCharging: Bool = false

    @Published var detectedDeviceName: String = "Galaxy Buds3 Pro"
    @Published var lastRSSI: Int? = nil
    @Published var lastUpdated: Date? = nil

    // Ham BLE Veri Monitörü (Kalibrasyon / Debug)
    @Published var lastRawPacket: [UInt8] = []
    @Published var packetCount: Int = 0

    // Kalibrasyon için ayarlanabilir bayt indeksleri (Samsung 0x42 beacon varsayılanları)
    @Published var leftByteIndex: Int = 34 {
        didSet { reparseLastPacket() }
    }
    @Published var rightByteIndex: Int = 35 {
        didSet { reparseLastPacket() }
    }
    @Published var caseByteIndex: Int = 33 {
        didSet { reparseLastPacket() }
    }

    private var centralManager: CBCentralManager!
    private var lastWidgetReload: Date = .distantPast

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn {
            startScanning()
        } else {
            isScanning = false
        }
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let isBudsByName = localName.localizedCaseInsensitiveContains("buds")

        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            if isBudsByName {
                detectedDeviceName = localName
                lastRSSI = RSSI.intValue
            }
            return
        }

        let bytes = [UInt8](manufacturerData)

        // Samsung Electronics Company ID: 0x0075 (little-endian: [0x75, 0x00])
        guard bytes.count >= 3, bytes[0] == 0x75, bytes[1] == 0x00 else {
            return
        }

        // Yalnızca gerçek Samsung Buds pil beacon paketlerini (0x42 ve en az 36 bayt) işle
        guard bytes[2] == 0x42, bytes.count >= 36 else { return }

        if !localName.isEmpty {
            detectedDeviceName = localName
        }
        lastRSSI = RSSI.intValue
        lastUpdated = Date()
        lastRawPacket = bytes
        packetCount += 1

        parseBatteryBytes(from: bytes)
    }

    func reparseLastPacket() {
        guard !lastRawPacket.isEmpty else { return }
        parseBatteryBytes(from: lastRawPacket)
    }

    private func parseBatteryBytes(from bytes: [UInt8]) {
        if let left = decodeBatteryByte(at: leftByteIndex, in: bytes) {
            leftBattery = left.level
            isLeftCharging = left.isCharging
        }

        if let right = decodeBatteryByte(at: rightByteIndex, in: bytes) {
            rightBattery = right.level
            isRightCharging = right.isCharging
        }

        if let caseInfo = decodeBatteryByte(at: caseByteIndex, in: bytes) {
            caseBattery = caseInfo.level
            isCaseCharging = caseInfo.isCharging
        }

        syncWidgetStore()
    }

    private func syncWidgetStore() {
        let defaults = UserDefaults(suiteName: "group.com.buds3pro.monitor") ?? .standard
        if let leftBattery { defaults.set(leftBattery, forKey: "buds_left_battery") }
        if let rightBattery { defaults.set(rightBattery, forKey: "buds_right_battery") }
        if let caseBattery { defaults.set(caseBattery, forKey: "buds_case_battery") }
        defaults.set(isLeftCharging, forKey: "buds_left_charging")
        defaults.set(isRightCharging, forKey: "buds_right_charging")
        defaults.set(isCaseCharging, forKey: "buds_case_charging")
        defaults.set(Date(), forKey: "buds_last_updated")

        let now = Date()
        if now.timeIntervalSince(lastWidgetReload) >= 15 {
            lastWidgetReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Samsung pil baytı çözümleyici:
    /// Alt 7 bit (`byte & 0x7F`) 0–100 pil yüzdesini, en yüksek bit (`byte & 0x80`) şarj durumunu belirtir.
    private func decodeBatteryByte(at index: Int, in bytes: [UInt8]) -> (level: Int, isCharging: Bool)? {
        guard index >= 0, index < bytes.count else { return nil }
        let raw = bytes[index]
        let level = Int(raw & 0x7F)
        let charging = (raw & 0x80) != 0
        guard level <= 100 else { return nil }
        return (level, charging)
    }

    var bluetoothStateDescription: String {
        switch bluetoothState {
        case .poweredOn:
            return isScanning ? "Bluetooth Açık • Pasif Tarama Aktif" : "Bluetooth Açık"
        case .poweredOff:
            return "Bluetooth Kapalı"
        case .unauthorized:
            return "Bluetooth İzni Reddedildi"
        case .unsupported:
            return "Bu Cihazda BLE Desteklenmiyor"
        case .resetting:
            return "Bluetooth Sıfırlanıyor..."
        default:
            return "Bluetooth Durumu Bekleniyor..."
        }
    }
}

// MARK: - Audio Route & Find My Earbuds Manager

private final class ChirpSignalState {
    var phase: Double = 0.0
    var elapsedSamples: Double = 0.0
}

final class BudsAudioManager: ObservableObject {
    @Published var isBluetoothAudioConnected: Bool = false
    @Published var connectedOutputName: String = "Bağlı Ses Cihazı Yok"
    @Published var connectedPortLabel: String = ""
    @Published var isPlayingAlert: Bool = false
    @Published var audioErrorMessage: String? = nil

    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private let signalState = ChirpSignalState()
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        configureObservers()
        refreshAudioRoute()
    }

    deinit {
        stopAlertTone()
        if let routeObserver = routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        if let interruptionObserver = interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    private func configureObservers() {
        let center = NotificationCenter.default
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAudioRoute()
        }

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let info = notification.userInfo,
                let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }

            if type == .began {
                self?.stopAlertTone()
            }
        }
    }

    func refreshAudioRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if let btOutput = outputs.first(where: {
            $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothHFP ||
            $0.portType == .bluetoothLE
        }) {
            isBluetoothAudioConnected = true
            connectedOutputName = btOutput.portName
            switch btOutput.portType {
            case .bluetoothA2DP:
                connectedPortLabel = "A2DP"
            case .bluetoothHFP:
                connectedPortLabel = "HFP"
            default:
                connectedPortLabel = "BLE Audio"
            }
        } else {
            isBluetoothAudioConnected = false
            connectedOutputName = "Kulaklık Ses Bağlantısı Yok"
            connectedPortLabel = ""
        }
    }

    func toggleAlertTone() {
        if isPlayingAlert {
            stopAlertTone()
        } else {
            startAlertTone()
        }
    }

    func startAlertTone() {
        audioErrorMessage = nil
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            audioErrorMessage = "Ses oturumu başlatılamadı: \(error.localizedDescription)"
            return
        }

        let engine = AVAudioEngine()
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 44_100.0
        guard let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: outputFormat.channelCount > 0 ? outputFormat.channelCount : 2
        ) else {
            audioErrorMessage = "Ses formatı oluşturulamadı."
            return
        }

        let state = signalState
        state.phase = 0.0
        state.elapsedSamples = 0.0

        // Yüksek frekanslı (3.1 kHz) periyodik "Kulaklığımı Bul" uyarı tonu (0.32s açık, 0.22s kapalı)
        let frequency: Double = 3_100.0
        let periodSeconds: Double = 0.54
        let onDurationSeconds: Double = 0.32
        let amplitude: Float = 0.85

        let node = AVAudioSourceNode(format: renderFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let twoPi = 2.0 * Double.pi
            let phaseIncrement = twoPi * frequency / sampleRate

            for frame in 0..<Int(frameCount) {
                let timeInCycle = (state.elapsedSamples / sampleRate).truncatingRemainder(dividingBy: periodSeconds)
                let sampleValue: Float

                if timeInCycle < onDurationSeconds {
                    // Yumuşak açılış/kapanış zarfı (tıkırtı önlemek için 10ms)
                    let fadeDuration = 0.01
                    var envelope: Double = 1.0
                    if timeInCycle < fadeDuration {
                        envelope = timeInCycle / fadeDuration
                    } else if timeInCycle > (onDurationSeconds - fadeDuration) {
                        envelope = max(0.0, (onDurationSeconds - timeInCycle) / fadeDuration)
                    }
                    sampleValue = Float(sin(state.phase) * envelope) * amplitude
                } else {
                    sampleValue = 0.0
                }

                state.phase += phaseIncrement
                if state.phase >= twoPi {
                    state.phase -= twoPi
                }
                state.elapsedSamples += 1.0

                for buffer in ablPointer {
                    let typedBuffer = UnsafeMutableBufferPointer<Float>(buffer)
                    if frame < typedBuffer.count {
                        typedBuffer[frame] = sampleValue
                    }
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)

        do {
            try engine.start()
            audioEngine = engine
            sourceNode = node
            isPlayingAlert = true
            refreshAudioRoute()
        } catch {
            audioErrorMessage = "Uyarı sesi çalınamadı: \(error.localizedDescription)"
            isPlayingAlert = false
        }
    }

    func stopAlertTone() {
        audioEngine?.stop()
        if let node = sourceNode {
            audioEngine?.detach(node)
        }
        sourceNode = nil
        audioEngine = nil
        isPlayingAlert = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Main UI (Galaxy Wearable Inspired)

struct ContentView: View {
    @StateObject private var bleManager = BudsBLEManager()
    @StateObject private var audioManager = BudsAudioManager()

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var isHexMonitorExpanded: Bool = false

    private var pageBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.06, green: 0.07, blue: 0.09)
            : Color(red: 0.95, green: 0.96, blue: 0.98)
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.13, blue: 0.17)
            : Color.white
    }

    private var cardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    deviceHeaderCard
                    batterySection
                    caseLidNotice
                    actionsCard
                    hexDumpSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle("Buds3 Pro")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        bleManager.startScanning()
                        audioManager.refreshAudioRoute()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("Taramayı Yenile")
                }
            }
        }
    }

    // MARK: - Header Card

    private var deviceHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.85), Color.indigo.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                    Image(systemName: "airpodspro")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(bleManager.detectedDeviceName)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(audioManager.isBluetoothAudioConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(audioManager.isBluetoothAudioConnected
                             ? "Ses Bağlı (\(audioManager.connectedPortLabel)): \(audioManager.connectedOutputName)"
                             : audioManager.connectedOutputName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let rssi = bleManager.lastRSSI {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text("\(rssi) dBm")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                Label(bleManager.bluetoothStateDescription, systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let updated = bleManager.lastUpdated {
                    Text(updated, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Battery Cards

    private var batterySection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                BatteryCardView(
                    title: "Sol Kulaklık",
                    shortLabel: "L",
                    systemIcon: "earbuds",
                    percentage: bleManager.leftBattery,
                    isCharging: bleManager.isLeftCharging,
                    cardBackground: cardBackground,
                    cardBorder: cardBorder
                )

                BatteryCardView(
                    title: "Sağ Kulaklık",
                    shortLabel: "R",
                    systemIcon: "earbuds",
                    percentage: bleManager.rightBattery,
                    isCharging: bleManager.isRightCharging,
                    cardBackground: cardBackground,
                    cardBorder: cardBorder
                )
            }

            BatteryCardView(
                title: "Şarj Kutusu",
                shortLabel: "Kutu",
                systemIcon: "earbuds.case",
                percentage: bleManager.caseBattery,
                isCharging: bleManager.isCaseCharging,
                cardBackground: cardBackground,
                cardBorder: cardBorder,
                isWide: true
            )
        }
    }

    // MARK: - Case Lid Info Label

    private var caseLidNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundColor(.blue)
                .padding(.top, 1)
            Text("Şarj kutusu kapağı kapalıyken kutu pil yüzdesi güncellenmeyebilir. Güncel değeri görmek için kapağı kısa süre açın.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(colorScheme == .dark ? 0.14 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions (Find My Earbuds & Bluetooth Settings)

    private var actionsCard: some View {
        VStack(spacing: 12) {
            Button {
                audioManager.toggleAlertTone()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: audioManager.isPlayingAlert ? "stop.circle.fill" : "speaker.wave.3.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(audioManager.isPlayingAlert ? "Uyarı Sesini Durdur" : "Kulaklığımı Bul")
                            .font(.headline)
                        Text(audioManager.isPlayingAlert
                             ? "Yüksek sesli uyarı tonu çalınıyor..."
                             : "Bağlı kulaklığa yüksek sesli uyarı tonu gönder")
                            .font(.caption)
                            .opacity(0.9)
                    }
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(16)
                .background(
                    audioManager.isPlayingAlert
                        ? Color.red
                        : Color.blue
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if !audioManager.isBluetoothAudioConnected {
                Text("Uyarı sesinin kulaklıktan çalması için Buds3 Pro'nun iOS Bluetooth ses çıkışı olarak bağlı olduğundan emin olun.")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage = audioManager.audioErrorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                openBluetoothSettings()
            } label: {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.blue)
                    Text("iOS Bluetooth Ayarlarını Aç")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(14)
                .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Raw BLE Hex Dump (Calibration / Debug Mode)

    private var hexDumpSection: some View {
        DisclosureGroup(isExpanded: $isHexMonitorExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Yakalanan Paket: \(bleManager.packetCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Uzunluk: \(bleManager.lastRawPacket.count) bayt")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                if bleManager.lastRawPacket.isEmpty {
                    Text("Henüz Samsung (0x0075) BLE paketi yakalanmadı. Kulaklık kutusunu açıp bekleyin.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Text(formattedHexDump(bleManager.lastRawPacket))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(colorScheme == .dark ? Color.black.opacity(0.45) : Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Bayt İndeksi Kalibrasyonu")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    Stepper("Sol İndeks: [\(bleManager.leftByteIndex)]", value: $bleManager.leftByteIndex, in: 2...45)
                        .font(.caption.monospacedDigit())
                    Stepper("Sağ İndeks: [\(bleManager.rightByteIndex)]", value: $bleManager.rightByteIndex, in: 2...45)
                        .font(.caption.monospacedDigit())
                    Stepper("Kutu İndeks: [\(bleManager.caseByteIndex)]", value: $bleManager.caseByteIndex, in: 2...45)
                        .font(.caption.monospacedDigit())
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .foregroundColor(.indigo)
                Text("Ham BLE Veri Monitörü (Hex Dump)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Helpers

    private func formattedHexDump(_ bytes: [UInt8]) -> String {
        bytes.enumerated()
            .map { index, byte in
                String(format: "[%02d]: 0x%02X", index, byte)
            }
            .joined(separator: ", ")
    }

    private func openBluetoothSettings() {
        if let btURL = URL(string: "App-Prefs:root=Bluetooth") {
            openURL(btURL) { accepted in
                if !accepted, let fallbackURL = URL(string: "app-settings:") {
                    openURL(fallbackURL)
                }
            }
        } else if let fallbackURL = URL(string: "app-settings:") {
            openURL(fallbackURL)
        }
    }
}

// MARK: - Battery Card Subview

private struct BatteryCardView: View {
    let title: String
    let shortLabel: String
    let systemIcon: String
    let percentage: Int?
    let isCharging: Bool
    let cardBackground: Color
    let cardBorder: Color
    var isWide: Bool = false

    private var statusColor: Color {
        guard let value = percentage else { return .gray }
        if value > 50 {
            return .green
        } else if value >= 20 {
            return .orange
        } else {
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Text(shortLabel)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.9))
                        .clipShape(Capsule())

                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                Spacer()

                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.subheadline)
                        .foregroundColor(.yellow)
                        .accessibilityLabel("Şarj oluyor")
                } else {
                    Image(systemName: systemIcon)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(percentage.map { "%\($0)" } ?? "--")
                    .font(.system(size: isWide ? 30 : 28, weight: .bold, design: .rounded))
                    .foregroundColor(percentage == nil ? .secondary : statusColor)
                    .monospacedDigit()

                if isCharging {
                    Text("Şarj Oluyor")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)

                    Capsule()
                        .fill(statusColor)
                        .frame(
                            width: geo.size.width * CGFloat(max(0, min(100, percentage ?? 0))) / 100.0,
                            height: 8
                        )
                        .animation(.easeInOut(duration: 0.3), value: percentage)
                }
            }
            .frame(height: 8)
        }
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
