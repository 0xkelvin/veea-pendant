// Read-only macOS Bluetooth discovery: no connections or writes.
import Foundation
import CoreBluetooth

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var found = Set<UUID>()
    var timer: Timer?
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.central.stopScan()
            print("Scan finished: \(self.found.count) distinct devices. No connections or writes.")
            exit(0)
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Bluetooth state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        } else if central.state == .unauthorized || central.state == .unsupported || central.state == .poweredOff {
            print("Bluetooth scanning is unavailable."); exit(2)
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard found.insert(peripheral.identifier).inserted else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unnamed"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        print("\(name) | RSSI \(RSSI) | services \(services.map(\.uuidString).joined(separator: ","))")
    }
}
let scanner = Scanner()
RunLoop.main.run()
