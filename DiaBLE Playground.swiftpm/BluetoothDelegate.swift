import Foundation
import CoreBluetooth


class BluetoothDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, Logging {

    var main: MainDelegate!
    var centralManager: CBCentralManager { main.centralManager }

    /// [uuid: (name, peripheral, advertisement, isConnectable, isIgnored)]
    @Published var knownDevices: [String: (name: String, peripheral: CBPeripheral, advertisement: [String: Any], isConnectable: Bool, isIgnored: Bool)] = [:]


    public func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOff:
            log("Bluetooth: state: powered off")
            main.errorStatus("Bluetooth powered off")
            if app.device != nil {
                manager.cancelPeripheralConnection(app.device.peripheral!)
                app.device.state = .disconnected
            }
            app.deviceState = "Disconnected"
        case .poweredOn:
            if settings.stoppedBluetooth {
                log("Bluetooth: state: powered on but stopped")
                main.errorStatus("Bluetooth on but stopped")
            } else {
                log("Bluetooth: state: powered on")
                if settings.preferredDevicePattern.matches("band"),
                   let peripheral = manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: BLE.UUID.heartRate.rawValue)]).first {
                    log("Bluetooth: retrieved \(peripheral.name ?? "unnamed peripheral")")
                    centralManager(centralManager, didDiscover: peripheral, advertisementData: [CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BLE.UUID.heartRate.rawValue)]], rssi: 0)
                } else if !(settings.preferredDevicePattern.matches("abbott") || settings.preferredDevicePattern.matches("dexcom")) {
                    main.status("Scanning...")
                    log("Bluetooth: scanning...")
                    manager.scanForPeripherals(withServices: nil, options: nil)
                } else {
                    // TODO: use manager.connect() after retrieval
                    if !settings.preferredDevicePattern.matches("dexcom"),
                       let peripheral = manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: Libre3.UUID.data.rawValue)]).first {
                        log("Bluetooth: retrieved \(peripheral.name ?? "unnamed peripheral")")
                        centralManager(centralManager, didDiscover: peripheral, advertisementData: [CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: Libre3.UUID.data.rawValue)]], rssi: 0)
                    } else if !settings.preferredDevicePattern.matches("dexcom"),
                              let peripheral = manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: Abbott.dataServiceUUID)]).first {
                        log("Bluetooth: retrieved \(peripheral.name ?? "unnamed peripheral")")
                        centralManager(centralManager, didDiscover: peripheral, advertisementData: [CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: Abbott.dataServiceUUID)]], rssi: 0)
                    } else if !settings.preferredDevicePattern.matches("abbott"),
                              let peripheral = manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: Dexcom.UUID.advertisement.rawValue)]).first {
                        log("Bluetooth: retrieved \(peripheral.name ?? "unnamed peripheral")")
                        centralManager(centralManager, didDiscover: peripheral, advertisementData: [CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: Dexcom.UUID.advertisement.rawValue)]], rssi: 0)
                    } else {
                        log("Bluetooth: scanning for a Libre/Dexcom...")
                        main.status("Scanning for a Libre/Dexcom...")
                        manager.scanForPeripherals(withServices: nil, options: nil)
                    }
                }
            }
        case .resetting:    log("Bluetooth: state: resetting")
        case .unauthorized: log("Bluetooth: state: unauthorized")
        case .unknown:      log("Bluetooth: state: unknown")
        case .unsupported:  log("Bluetooth: state: unsupported")
        @unknown default:
            log("Bluetooth: state: unknown")
        }
    }


    public func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData advertisement: [String: Any], rssi: NSNumber) {
        peripheral.delegate = self
        var name = peripheral.name
        let manufacturerData = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data
        let dataServiceUUIDs = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        let advertisedLocalName = advertisement[CBAdvertisementDataLocalNameKey] as? String
        if name == nil && advertisedLocalName != nil {
            name = advertisedLocalName
        }

        if let dataServiceUUIDs, dataServiceUUIDs.count > 0, dataServiceUUIDs[0].uuidString == Libre3.UUID.data.rawValue {
            name = "ABBOTT\(name ?? "unnamedLibre")"    // Libre 3 device name is 12 chars long (hexadecimal MAC address)
        }

        if let dataServiceUUIDs, dataServiceUUIDs.count > 0, dataServiceUUIDs[0].uuidString == Abbott.dataServiceUUID, !(name ?? "unnamedLibre").hasPrefix("ABBOTT") {
            name = "ABBOTT\(name ?? "unnamedLibre")"    // newer Libre 2+ EU device name is 12 chars long (hexadecimal MAC address)
        }

        if let dataServiceUUIDs = dataServiceUUIDs, dataServiceUUIDs.count > 0, dataServiceUUIDs[0].uuidString == Dexcom.UUID.advertisement.rawValue {
            // Dexcom G7 device name starts with "DXCM" instead of "Dexcom" (both end in the last two chars of the serial number)
            if name!.hasPrefix("DXCM") {
                name = "DEXCOMG7\(name!.suffix(2))"
            }
            // Dexcom ONE+ device name starts with "DX02")
            if name!.hasPrefix("DX02") {
                name = "DEXCOMONE+\(name!.suffix(2))"
            }
            // Stelo device name is in the form DX01xx
            if name!.hasPrefix("DX01") {
                name = "DEXCOMSTELO\(name!.suffix(2))"
            }
        }

        var didFindATransmitter = false

        if let name {
            for transmitterType in TransmitterType.allCases {
                if name.matches(transmitterType.id) {
                    didFindATransmitter = true
                    if settings.preferredTransmitter != .none && transmitterType != settings.preferredTransmitter {
                        didFindATransmitter = false
                    }
                }
            }
        }

        var companyId = BLE.companies.count - 1 // "< Unknown >"
        if let manufacturerData {
            companyId = Int(manufacturerData[0]) + Int(manufacturerData[1]) << 8
            if companyId >= BLE.companies.count { companyId = BLE.companies.count - 1 }    // when 0xFFFF
        }

        if name == nil {
            name = "an unnamed peripheral"
            if BLE.companies[companyId].name != "< Unknown >" {
                name = "\(BLE.companies[companyId].name)'s unnamed peripheral"
            }
        }

        let identifier = peripheral.identifier.uuidString
        let deviceIsConnectable = advertisement[CBAdvertisementDataIsConnectable] as? Int ?? 1 != 0
        var deviceIsIgnored = false
        var msg = "Bluetooth: \(name!)'s device identifier \(identifier)"
        if knownDevices[identifier] == nil {
            msg += " not yet known"
            knownDevices[identifier] = (name!.contains("unnamed") ? name! : peripheral.name!, peripheral, advertisement, deviceIsConnectable, deviceIsIgnored)
            if settings.userLevel > .basic {
                msg += " (advertised data: \(advertisement)\(BLE.companies[companyId].name != "< Unknown >" ? ", company: \(BLE.companies[companyId].name)" : ""))"
            }
        } else {
            msg += " already known"
            deviceIsIgnored = knownDevices[identifier]!.isIgnored
        }
        debugLog(msg)

        if !deviceIsConnectable
            || deviceIsIgnored
            || (didFindATransmitter && !settings.preferredDevicePattern.isEmpty && !name!.matches(settings.preferredDevicePattern))
            || (!didFindATransmitter && (settings.preferredTransmitter != .none || (!settings.preferredDevicePattern.isEmpty && !name!.matches(settings.preferredDevicePattern)))) {
            var scanningFor = "Scanning"
            if !settings.preferredDevicePattern.isEmpty {
                scanningFor += " for '\(settings.preferredDevicePattern)'"
            }
            main.status("\(scanningFor)...\nSkipped \(name!)")
            msg = "Bluetooth: skipped \(name!)"
            if !deviceIsConnectable {
                if !settings.preferredDevicePattern.isEmpty && name!.matches(settings.preferredDevicePattern) {
                    msg += " because not connectable"
                    main.errorStatus("(not connectable)")
                }
            }
            if deviceIsIgnored {
                if !settings.preferredDevicePattern.isEmpty && name!.matches(settings.preferredDevicePattern) {
                    msg += " because ignored"
                    main.errorStatus("(ignored)")
                }
            }
            msg += ", \(scanningFor.lowercased())..."
            log(msg)
            return
        }

        manager.stopScan()
        if name!.lowercased().hasPrefix("abbott") {
            app.transmitter = Abbott(peripheral: peripheral, main: main)
            app.device = app.transmitter
            app.lastReadingDate = Date() // TODO
            if name!.count == 18 { // fictitious "ABBOTT" + Libre 3/2+ hexadecimal MAC address
                name = String(name!.suffix(12))
                if name != "unnamedLibre" {
                    app.device.macAddress = name!.bytes
                }
                if dataServiceUUIDs![0].uuidString == Libre3.UUID.data.rawValue {
                    app.device.name = "Libre 3"
                    (app.transmitter as! Abbott).securityGeneration = 3
                } else if dataServiceUUIDs![0].uuidString == Abbott.dataServiceUUID {
                    app.device.name = "Libre 2"
                    (app.transmitter as! Abbott).securityGeneration = 1
                }
            } else {
                app.device.serial = String(name!.suffix(name!.count - 6))
                switch app.device.serial.prefix(1) {
                case "7":
                    app.device.name = "Libre Sense"
                    (app.transmitter as! Abbott).securityGeneration = 2
                case "3":
                    app.device.name = "Libre 2"
                default: app.device.name = "Libre"
                    // TODO: Libre 2 US / CA
                }
            }
            settings.activeSensorSerial = app.device.serial

        } else if name!.lowercased().hasPrefix("dexcom") {
            app.transmitter = Dexcom(peripheral: peripheral, main: main)
            app.device = app.transmitter
            if name!.hasPrefix("Dexcom") {
                app.device.name = "Dexcom"         // TODO: separate Dexcom G6 and ONE
            } else if name!.hasPrefix("DEXCOMG7") {  // restore to the original G7 device name
                app.device.name = "Dexcom G7"
                name = "DXCM" + name!.suffix(2)
            } else if name!.hasPrefix("DEXCOMONE+") {  // restore to the original ONE+ device name
                app.device.name = "Dexcom ONE+"
                name = "DX02" + name!.suffix(2)
            } else if name!.hasPrefix("DEXCOMSTELO") {  // restore to the original Stelo device name
                app.device.name = "Stelo"
                name = "DX01" + name!.suffix(2)
            }
            let serialSuffix = name!.suffix(2)
            if !(settings.activeTransmitterSerial.count == 6 && settings.activeTransmitterSerial.suffix(2) == serialSuffix) {
                app.device.serial = "XXXX" + name!.suffix(2)
                settings.activeTransmitterSerial = app.device.serial
            } else {
                app.device.serial = settings.activeTransmitterSerial
            }

            // } else if name.matches("custom") {
            //    custom = Custom(peripheral: peripheral, main: main)
            //    app.device = custom
            //    app.device.name = peripheral.name!
            //    app.transmitter = custom.transmitter
            //    app.transmitter.name = "bridge"

        } else {
            app.device = Device(peripheral: peripheral, main: main)
            app.device.name = name!.replacingOccurrences(of: "an unnamed", with: "Unnamed")
        }

        app.device.rssi = Int(truncating: rssi)
        app.device.company = BLE.companies[companyId].name
        msg = "Bluetooth: found \(name!): RSSI: \(rssi), advertised data: \(advertisement)"
        if app.device.company == "< Unknown >" {
            if companyId != BLE.companies.count - 1 {
                msg += ", company id: \(companyId) (0x\(companyId.hex), unknown)"
            }
        } else {
            msg += ", company: \(app.device.company) (id: 0x\(companyId.hex))"
        }
        log(msg)
        if let manufacturerData {
            app.device.parseManufacturerData(manufacturerData)
        }
        if let dataServiceUUIDs {
            // TODO: assign to device instance vars
            log("Bluetooth: \(name!)'s advertised data service UUIDs: \(dataServiceUUIDs)")
        }
        main.status("\(app.device.name)")
        app.device.peripheral?.delegate = self
        log("Bluetooth: connecting to \(name!)...")
        manager.connect(app.device.peripheral!, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        app.device.state = app.device.peripheral!.state
        app.deviceState = app.device.state.description.capitalized + "..."
    }


    public func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "an unnamed peripheral"
        let identifier = peripheral.identifier.uuidString
        var msg = "Bluetooth: \(name) has \(identifier != app.device.peripheral?.identifier.uuidString ? "connected" : "reconnected") (identifier: \(identifier))"
        app.device.state = peripheral.state
        app.deviceState = app.device.state.description.capitalized
        app.device.lastConnectionDate = Date()
        app.lastConnectionDate = app.device.lastConnectionDate
        // TODO:
        // manager.registerForConnectionEvents(
        //     options: [
        //         CBConnectionEventMatchingOption(rawValue: CBConnectPeripheralOptionEnableAutoReconnect): true,
        //         .peripheralUUIDs: [peripheral.identifier]
        //     ]
        // )
        // log("Bluetooth: registerForConnectionEvents: options: [\(CBConnectPeripheralOptionEnableAutoReconnect): true, .peripheralUUIDs: [\(peripheral.identifier)])")
        if identifier == app.device.peripheral?.identifier.uuidString {
            let knownCharacteristics = app.device.characteristics
            if knownCharacteristics.count > 0 {
                debugLog("Bluetooth: \(name)'s known characteristics: \(knownCharacteristics.debugDescription)")
                // TODO: skip redescovering
            }
        }
        msg += ("; discovering services")
        peripheral.discoverServices(nil)
        main.status("\(app.device.name)")
        log(msg)
    }


    public func centralManager(_ manager: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        log("Bluetooth: '\(["peer disconnected", "peer connected"][event.rawValue])' connection event did occur for \(peripheral.name ?? "an unnamed") peripheral")
    }


    public func centralManager(_ manager: CBCentralManager, willRestoreState dict: [String: Any]) {
        log("Bluetooth: will restore state to \(dict.debugDescription)")
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in restoredPeripherals {
                let identifier = peripheral.identifier.uuidString
                let name = peripheral.name ?? "an unnamed peripheral"
                let knownDevice = knownDevices[identifier]
                let advertisement = knownDevice?.advertisement ?? [:]
                let isConnectable = knownDevice?.isConnectable ?? true
                let isIgnored = knownDevice?.isIgnored ?? false
                knownDevices[identifier] = (name: name, peripheral: peripheral, advertisement, isConnectable: isConnectable, isIgnored: isIgnored)
                log("TODO: Bluetooth: restoring peripheral \(name), identifier: \(identifier), connectable: \(isConnectable), ignored: \(isIgnored)")
                // TODO
                // switch peripheral.state {
                    main.status("Reconnecting to \(name)...")
                    log("Bluetooth: reconnecting to restored peripheral \(name)...")
                    manager.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
                // }
            }
        }
    }


    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let name = peripheral.name ?? "unnamed peripheral"
        if app.device.name == "Unnamed peripheral" && name != "unnamed peripheral" {
            app.device.name = name
            main.status("\(app.device.name)")
            knownDevices[peripheral.identifier.uuidString]!.name = name
        }
        app.device.state = peripheral.state
        if let services = peripheral.services {
            for service in services {
                let serviceUUID = service.uuid.uuidString
                var description = "unknown service"
                if serviceUUID == type(of: app.device).dataServiceUUID {
                    description = "data service"
                }
                if [Libre3.UUID.data.rawValue, Libre3.UUID.security.rawValue].contains(serviceUUID) {
                    description = Libre3.UUID(rawValue: serviceUUID)!.description
                }
                if let uuid = BLE.UUID(rawValue: serviceUUID) {
                    description = uuid.description
                }
                var msg = "Bluetooth: discovered \(name)'s service \(serviceUUID) (\(description))"
                if !(serviceUUID == BLE.UUID.device.rawValue && app.device.characteristics[BLE.UUID.manufacturer.rawValue] != nil) {
                    msg += "; discovering characteristics"
                    peripheral.discoverCharacteristics(nil, for: service)
                }
                log(msg)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else {
            log("Bluetooth: unable to retrieve service characteristics")
            return
        }

        let serviceUUID = service.uuid.uuidString
        var serviceDescription = serviceUUID
        if serviceUUID == type(of: app.device).dataServiceUUID || serviceUUID == Libre3.UUID.data.rawValue {
            serviceDescription = "data"
        }

        for characteristic in characteristics {
            let uuid = characteristic.uuid.uuidString

            var msg = "Bluetooth: discovered \(app.device.name) \(serviceDescription) service's characteristic \(uuid)"
            msg += (", properties: \(characteristic.properties)")

            if Libre3.knownUUIDs.contains(uuid) {
                msg += " (\(Libre3.UUID(rawValue: uuid)!.description))"
            }

            if Dexcom.knownUUIDs.contains(uuid) {
                msg += " (\(Dexcom.UUID(rawValue: uuid)!.description))"
                let transmitterIsAuthenticated = (app.transmitter as? Dexcom)?.authenticated ?? false

                if uuid == Dexcom.UUID.control.rawValue {
                    app.device.readCharacteristic = characteristic
                    app.device.writeCharacteristic = characteristic
                    if settings.userLevel >= .test && transmitterIsAuthenticated {
                        peripheral.setNotifyValue(true, for: characteristic)
                        msg += "; enabling notifications"
                    } else {
                        msg += "; avoid enabling notifications because of 'Encryption is insufficient' error"
                    }

                } else if uuid == Dexcom.UUID.backfill.rawValue
                            || uuid == Dexcom.UUID.communication.rawValue {
                    if settings.userLevel >= .test && transmitterIsAuthenticated {
                        peripheral.setNotifyValue(true, for: characteristic)
                        msg += "; enabling notifications"
                    } else {
                        msg += "; avoid enabling notifications because of 'Encryption is insufficient' error"
                    }

                } else {
                    peripheral.setNotifyValue(true, for: characteristic)
                    msg += "; enabling notifications"
                }

            } else if uuid == Libre3.UUID.patchStatus.rawValue {
                msg += "; avoid enabling notifications because of 'Encryption is insufficient' error"

            } else if uuid == Libre3.UUID.oneMinuteReading.rawValue && settings.userLevel < .test {  // not eavesdropping on Trident
                msg += "; postoponing enabling notifications"

            } else if uuid == Abbott.dataReadCharacteristicUUID {
                app.device.readCharacteristic = characteristic
                msg += " (data read)"

                // enable notifications only in didWriteValueFor() unless eavesdropping on the Libre 2 in TEST mode
                if uuid != Abbott.dataReadCharacteristicUUID || settings.userLevel >= .test {
                    app.device.peripheral?.setNotifyValue(true, for: app.device.readCharacteristic!)
                    msg += "; enabling notifications"
                }

            } else if uuid == Abbott.dataWriteCharacteristicUUID {
                msg += " (data write)"
                app.device.writeCharacteristic = characteristic


            // } else if let uuid = Custom.UUID(rawValue: uuid) {
            //    msg += " (\(uuid))"
            //    if uuid.description.contains("unknown") {
            //        if characteristic.properties.contains(.notify) {
            //            app.device.peripheral?.setNotifyValue(true, for: characteristic)
            //        }
            //        if characteristic.properties.contains(.read) {
            //            app.device.peripheral?.readValue(for: characteristic)
            //            msg += "; reading it"
            //        }
            //    }


            } else if let uuid = BLE.UUID(rawValue: uuid) {
                if uuid == .batteryLevel || uuid == .heartRateMeasurement || uuid == .bloodPressureMeasurement {
                    app.device.peripheral?.setNotifyValue(true, for: characteristic)
                }

                if app.device.characteristics[uuid.rawValue] != nil {
                    msg += " (\(uuid)); already read it"
                } else {
                    app.device.peripheral?.readValue(for: characteristic)
                    msg += " (\(uuid)); reading it"
                }

                // } else if let uuid = OtherDevice.UUID(rawValue: uuid) {
                //    msg += " (\(uuid))"

            } else {
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    msg += "; enabling notifications"
                }
                if characteristic.properties.contains(.read) || characteristic.properties.contains(.indicate) {
                    peripheral.readValue(for: characteristic)
                    msg += "; reading it"
                }
            }

            log(msg)

            app.device.characteristics[uuid] = characteristic

        }

        if app.device.type == .transmitter(.abbott) && (serviceUUID == Abbott.dataServiceUUID || serviceUUID == Libre3.UUID.data.rawValue || serviceUUID == Libre3.UUID.security.rawValue) {
            var sensor: Sensor! = app.sensor
            if app.sensor == nil || (app.sensor.transmitter != nil && app.sensor.transmitter?.type != app.device.type && sensor.uid != (app.device as! Abbott).sensorUid) {
                if serviceUUID == Libre3.UUID.data.rawValue {
                    sensor = Libre3(transmitter: app.transmitter)
                } else {
                    sensor = Libre2(transmitter: app.transmitter)
                }
                app.sensor = sensor
                sensor.state = .active
                if serviceUUID != Libre3.UUID.data.rawValue {
                    sensor.uid = (app.device as! Abbott).sensorUid
                    // TODO
                    settings.currentSensorUid = sensor.uid
                }
                if settings.activeSensorSerial == app.device.serial {
                    if !app.device.serial.isEmpty && !settings.currentPatchInfo.isEmpty {
                        (sensor as! Libre).patchInfo = settings.currentPatchInfo

                    } else {
                        sensor.serial = app.device.serial
                        var family = Int(app.device.serial.prefix(1)) ?? 0
                        switch family {
                        case 3:  sensor.type = .libre2
                        case 0:  sensor.type = .libre3; family = 4
                        default: sensor.type = .libre2
                        }
                        sensor.family = SensorFamily(rawValue: family) ?? .libre2
                    }
                }
            }

            app.transmitter.sensor = sensor

            if !app.device.serial.isEmpty && app.device.serial == settings.activeSensorSerial {
                (sensor as? Libre2)?.initialPatchInfo = settings.activeSensorInitialPatchInfo
                (sensor as? Libre2)?.streamingUnlockCode = UInt32(settings.activeSensorStreamingUnlockCode)
                (sensor as? Libre2)?.streamingUnlockCount = UInt16(settings.activeSensorStreamingUnlockCount)
                sensor.calibrationInfo = settings.activeSensorCalibrationInfo
                sensor.maxLife = settings.activeSensorMaxLife
                var msg = "Bluetooth: the active sensor \(app.device.serial) has reconnected"
                if let libre2 = sensor as? Libre2 {
                    msg += "; restoring settings: initial patch info: \(libre2.initialPatchInfo.hex), current patch info: \(libre2.patchInfo.hex), unlock count: \(libre2.streamingUnlockCount)"
                }
                log(msg)
                app.device.macAddress = settings.activeSensorAddress
            }

            if serviceUUID == Libre3.UUID.security.rawValue {
                if sensor.transmitter == nil { sensor.transmitter = app.transmitter }
                sensor.maxLife = settings.activeSensorMaxLife != 0 ? settings.activeSensorMaxLife : 21600
                if settings.userLevel < .test { // not eavesdropping on Trident
                    ((app.device as? Abbott)?.sensor as? Libre3)?.send(securityCommand: .authorizeSymmetric)
                }

            } else if (app.transmitter as! Abbott).securityGeneration == 2 && (app.transmitter as! Abbott).authenticationState == .notAuthenticated {
                app.device.peripheral?.setNotifyValue(true, for: app.device.writeCharacteristic!)
                (app.transmitter as! Abbott).authenticationState = .enableNotification
                debugLog("Bluetooth: enabled \(app.device.name) security notification")
                // TODO: move to didUpdateNotificationStateFor()
                (app.transmitter as! Abbott).authenticationState = .challengeResponse
                app.device.write(Data([0x20]), .withResponse)
                debugLog("Bluetooth: sent \(app.device.name) read security challenge")

            } else if sensor.uid.count > 0 && settings.activeSensorInitialPatchInfo.count > 0 {
                if let libre2 = sensor as? Libre2, settings.userLevel < .test {  // not eavesdropping on Libre 2
                    libre2.streamingUnlockCount += 1
                    settings.activeSensorStreamingUnlockCount += 1
                    let unlockPayload = Libre2.streamingUnlockPayload(id: sensor.uid, info: settings.activeSensorInitialPatchInfo, enableTime: libre2.streamingUnlockCode, unlockCount: libre2.streamingUnlockCount)
                    log("Bluetooth: writing streaming unlock payload: \(Data(unlockPayload).hex) (patch info: \(settings.activeSensorInitialPatchInfo.hex), unlock code: \(libre2.streamingUnlockCode), unlock count: \(libre2.streamingUnlockCount), sensor id: \(libre2.uid.hex), current patch info: \(libre2.patchInfo.hex))")
                    app.device.write(unlockPayload, .withResponse)
                }
            }
        }

        if app.device.type == .transmitter(.dexcom) && serviceUUID == Dexcom.dataServiceUUID {
            var sensor: Sensor! = app.sensor
            if sensor == nil || sensor.type != .dexcomG6 || sensor.type != .dexcomONE || sensor.type != .dexcomG7 || sensor.type != .dexcomONEPlus {
                if app.device.name.suffix(2) == "G7" {
                    sensor = DexcomG7(transmitter: app.transmitter)
                    sensor.type = .dexcomG7
                } else if app.device.name.suffix(4) == "ONE+" {
                    sensor = DexcomONEPlus(transmitter: app.transmitter)
                    sensor.type = .dexcomONEPlus
                } else if app.device.name.prefix(5) == "Stelo" {
                    sensor = Stelo(transmitter: app.transmitter)
                    sensor.type = .stelo
                } else {
                    // TODO: default type should be DexcomG6
                    sensor = DexcomONE(transmitter: app.transmitter)
                    sensor.type = .dexcomONE
                }
                app.sensor = sensor
            }
            app.transmitter.sensor = sensor
            if settings.userLevel < .test { // not eavesdropping

                // G7 uses appKeyChallenge/authRequest2Tx (0x02), see: https://github.com/NightscoutFoundation/xDrip/blob/master/libkeks/src/main/java/jamorham/keks/message/AuthRequestTxMessage2.java
                // TODO: send 01 00 first anyway
                var message = (sensor.type == .dexcomG7 || sensor.type == .stelo || sensor.type == .dexcomONEPlus || sensor.type == .dexcomONE) ? DexcomG7.Opcode.appKeyChallenge.data : Dexcom.Opcode.authRequestTx.data
                let singleUseToken = UUID().uuidString.data(using: .utf8)!.prefix(8)
                message += singleUseToken
                message.append(0x02)
                log("Bluetooth: sending \(app.device.name) authentication request: \(message.hex)")
                app.device.write(message, for: Dexcom.UUID.authentication.rawValue, .withResponse)

                // TEST: first JPake phase: send exchangePakePayload 0a + 00 phase
                if sensor.type == .dexcomG7 || sensor.type == .stelo || sensor.type == .dexcomONEPlus || sensor.type == .dexcomONE {
                    let message = Dexcom.Opcode.exchangePakePayload.data + Dexcom.PakePhase.zero.rawValue.data
                    log("TEST: sending \(app.device.name) 'exchangePakePayload phase zero' command \(message.hex)")
                    app.device.write(message, for: Dexcom.UUID.authentication.rawValue, .withResponse)
                }

            }
        }
    }


    public func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        let name = peripheral.name ?? "an unnamed peripheral"
        app.device?.state = peripheral.state
        app.deviceState = peripheral.state.description.capitalized
        if error != nil {
            log("Bluetooth: \(name) has disconnected at \(Date(timeIntervalSinceReferenceDate: timestamp).shortTime), is reconnecting: \(isReconnecting)")
            let errorCode = CBError.Code(rawValue: (error! as NSError).code)! // 6 = timed out when out of range
            log("Bluetooth: error type \(errorCode.rawValue): \(error!.localizedDescription)")
            if isReconnecting {
                app.deviceState = "Reconnecting..."
                log("Bluetooth: reconnecting to \(name)...")
                if errorCode == .connectionTimeout { main.errorStatus("Connection timed out. Waiting...") }
                app.device.buffer = Data()
            } else {
                let lastConnectionDate = Date()
                app.device?.lastConnectionDate = lastConnectionDate
                app.lastConnectionDate = lastConnectionDate
                // app.device = nil
                // app.transmitter = nil
            }
        } else {
            log("Bluetooth: stopped connecting with \(name).")
            app.device.lastConnectionDate = Date()
            app.lastConnectionDate = app.device.lastConnectionDate
            // app.device = nil
            // app.transmitter = nil
        }
    }

    public func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? "an unnamed peripheral"
        var msg = "Bluetooth: failed to connect to \(name)"
        var errorCode: CBError.Code?

        if let error {
            errorCode = CBError.Code(rawValue: (error as NSError).code)
            msg += ", error type \(errorCode!.rawValue): \(error.localizedDescription)"
        }

        if let errorCode, errorCode == .peerRemovedPairingInformation {  // i.e. BluCon
            main.errorStatus("Failed to connect: \(error!.localizedDescription)")
        } else {
            msg += "; retrying..."
            main.errorStatus("Failed to connect, retrying...")
            manager.connect(app.device.peripheral!, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        }

        log(msg)
    }


    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let name = peripheral.name ?? "an unnamed peripheral"
        var characteristicString = characteristic.uuid.uuidString
        if [Abbott.dataWriteCharacteristicUUID].contains(characteristicString) {
            characteristicString = "data write"
        }
        if let characteristicDescription = Libre3.UUID(rawValue: characteristicString)?.description {
            characteristicString = characteristicDescription
        }
        if let characteristicDescription = Dexcom.UUID(rawValue: characteristicString)?.description {
            characteristicString = characteristicDescription
        }
        if error != nil {
            log("Bluetooth: error while writing \(name)'s \(characteristicString) characteristic value: \(error!.localizedDescription)")
        } else {
            log("Bluetooth: \(name) did write value for \(characteristicString) characteristic")
            if characteristic.uuid.uuidString == Abbott.dataWriteCharacteristicUUID {
                app.device.peripheral?.setNotifyValue(true, for: app.device.readCharacteristic!)
                log("Bluetooth: enabling data read notifications for \(name)")
            }
        }
    }


    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let name = peripheral.name ?? "an unnamed peripheral"
        var characteristicString = characteristic.uuid.uuidString
        if [Abbott.dataReadCharacteristicUUID].contains(characteristicString) {
            characteristicString = "data read"
        }
        if let characteristicDescription = Libre3.UUID(rawValue: characteristicString)?.description {
            characteristicString = characteristicDescription
        }
        if let characteristicDescription = Dexcom.UUID(rawValue: characteristicString)?.description {
            characteristicString = characteristicDescription
        }
        var msg = "Bluetooth: \(name) did update notification state for \(characteristicString) characteristic"
        msg += ": \(characteristic.isNotifying ? "" : "not ")notifying"
        if let descriptors = characteristic.descriptors { msg += ", descriptors: \(descriptors)" }
        if let error {
            let errorCode = CBError.Code(rawValue: (error as NSError).code)!
            if errorCode == .encryptionTimedOut {
                log("Bluetooth: DEBUG: TODO: manage pairing timeout")
                // TODO: manage pairing
            }
            msg += ", error: \(error.localizedDescription)"
        }
        log(msg)
    }


    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI rssi: NSNumber, error: Error?) {
        let name = peripheral.name ?? "an unnamed peripheral"
        if let error {
            debugLog("Bluetooth: error reading \(name)'s RSSI: \(error.localizedDescription)")
        } else {
            log("Bluetooth: did read \(name)'s RSSI: \(rssi) dB")
            app.device.rssi = Int(truncating: rssi)
        }
    }


    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let name = peripheral.name ?? "an unnamed peripheral"
        var characteristicString = characteristic.uuid.uuidString

        if [Abbott.dataReadCharacteristicUUID].contains(characteristicString) {
            characteristicString = "data read"
        }
        if let characteristicDescription = Libre3.UUID(rawValue: characteristicString)?.description {
            characteristicString = characteristicDescription
        }
        if let characteristicDescription = Dexcom.UUID(rawValue: characteristicString)?.description {
            characteristicString = characteristicDescription
        }

        guard let data = characteristic.value else {
            log("Bluetooth: \(name)'s error updating value for \(characteristicString) characteristic: \(error!.localizedDescription)")
            return
        }

        var msg = "Bluetooth: \(name) did update value for \(characteristicString) characteristic (\(data.count) bytes received):"
        if data.count > 0 {
            msg += " hex: \(data.hex),"
        }

        if let uuid = BLE.UUID(rawValue: characteristic.uuid.uuidString) {

            log("\(msg) \(uuid): \(uuid != .batteryLevel ? "\"\(data.string)\"" : String(Int(data[0])))")

            switch uuid {

            case .batteryLevel:
                app.device.battery = Int(data[0])
            case .model:
                app.device.model = data.string
                if app.device.peripheral?.name == nil {
                    app.device.name = app.device.model
                    main.status(app.device.name)
                }
            case .serial:
                app.device.serial = data.string
            case .firmware:
                app.device.firmware = data.string
            case .hardware:
                app.device.hardware += data.string
            case .software:
                app.device.software = data.string
            case .manufacturer:
                app.device.manufacturer = data.string

            case .heartRateMeasurement:
                parseHeartRate(data: data, device: app.device)

            case .bloodPressureMeasurement:
                parseBloodPressure(data: data, device: app.device)

            default:
                break
            }

        } else {

            log("\(msg) string: \"\(data.string)\"")


            if app.device == nil { return }     // the connection timed out in the meantime

            // Preserve the initial app.lastConnectionDate when multiple updates are coming
            if Int(app.device.lastConnectionDate.distance(to: Date())) > settings.readingInterval * 60 - 5 {
                app.device.peripheral!.readRSSI()
                app.device.lastConnectionDate = Date()
                app.lastConnectionDate = app.device.lastConnectionDate
            }

            app.device.read(data, for: characteristic.uuid.uuidString)

            if app.device.type == .transmitter(.abbott) {
                if app.transmitter.buffer.count == 46 {
                    main.didParseSensor(app.transmitter.sensor!)
                    app.transmitter.buffer = Data()
                }

            } else if app.device.type == .transmitter(.dexcom) {
                // TODO:
                // main.didParseSensor(app.transmitter.sensor!)
                return

            } else if app.transmitter?.sensor != nil {
                main.didParseSensor(app.transmitter.sensor!)
                app.transmitter.buffer = Data()
            }
        }
    }


    func parseHeartRate(data: Data, device: Device) {
        guard data.count > 0 else { return }

        var index = 0
        let flags = data[index]
        index += 1

        // Bit 0: Heart Rate Value Format (0: UInt8, 1: UInt16)
        let hrValueFormat = flags & 1 << 0 != 0

        // Bit 1: Sensor Contact Status support
        let sensorContactSupported = flags & 1 << 1 != 0

        // Bit 2: Sensor Contact Status
        let sensorInContact = flags & 1 << 2 != 0

        // Bit 3: Energy Expended Status support
        let energyExpendedSupported = flags & 1 << 3 != 0

        // Bit 4: RR-Interval presence
        let rrIntervalPresent = flags & 1 << 4 != 0

        var heartRate: Int
        if hrValueFormat {
            heartRate = Int(data[index]) + Int(data[index + 1]) << 8
            index += 2
        } else {
            heartRate = Int(data[index])
            index += 1
        }

        var energyExpended: Int?
        if energyExpendedSupported {
            energyExpended = Int(data[index]) + Int(data[index + 1]) << 8
            index += 2
        }

        // Time intervals between heartbeats
        var rrIntervals: [Int] = []
        if rrIntervalPresent {
            while index < data.count - 1 {
                let rrInterval = Int(data[index]) + Int(data[index + 1]) << 8
                rrIntervals.append(rrInterval)
                index += 2
            }
        }

        var msg = "heart rate: \(heartRate) BPM"

        if sensorContactSupported {
            msg.append(", sensor in contact: \(sensorInContact ? "yes" : "no")")
        }

        if let energyExpended {
            msg.append(", energy expended: \(energyExpended) kJ")
        }

        if !rrIntervals.isEmpty {
            msg.append(", RR-intervals: \(rrIntervals.map(String.init).joined(separator: ", "))")
        }

        log("Bluetooth: \(device.name): \(msg)")
    }


    func parseBloodPressure(data: Data, device: Device) {
        var index = 0

        let flags = data[index]
        index += 1

        let timestampPresent = flags & 1 << 1 != 0
        let pulseRatePresent = flags & 1 << 2 != 0

        let systolic = Int(data[index]) + Int(data[index + 1]) << 8
        index += 2

        let diastolic = Int(data[index]) + Int(data[index + 1]) << 8
        index += 2

        // Mean Arterial Pressure
        let map = Int(data[index]) + Int(data[index + 1]) << 8
        index += 2

        var timestamp: Date?
        if timestampPresent {
            let year = Int(data[index]) + Int(data[index + 1]) << 8
            let month = data[index + 2]
            let day = data[index + 3]
            let hour = data[index + 4]
            let minute = data[index + 5]
            let second = data[index + 6]
            index += 7

            let calendar = Calendar.current
            timestamp = calendar.date(from: DateComponents(year: Int(year), month: Int(month), day: Int(day), hour: Int(hour), minute: Int(minute), second: Int(second)))
        }

        var pulseRate: Int?
        if pulseRatePresent {
            pulseRate = Int(data[index]) + Int(data[index + 1]) << 8
            index += 2
        }

        var msg = "blood pressure: systolic: \(systolic), diastolic: \(diastolic), mean arterial pressure: \(map)"

        if let timestamp {
            msg.append(", timestamp: \(timestamp)")
        }
        if let pulseRate {
            msg.append(", pulse rate: \(pulseRate)")
        }

        log("Bluetooth: \(device.name): \(msg)")
    }

}
