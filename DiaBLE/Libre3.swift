import Foundation
import CryptoKit
import LibreCRKit

// https://insulinclub.de/index.php?thread/33795-free-three-ein-xposed-lsposed-modul-f%C3%BCr-libre-3-aktueller-wert-am-sperrbildschir/&postID=655055#post655055

extension String {
    /// Converts a LibreView account GUID string into a receiverID
    /// i.e. "2977dec2-492a-11ea-9702-0242ac110002" -> 524381581
    var fnv32Hash: UInt32 { UInt32(self.reduce(0) { 0xFFFFFFFF & (UInt64($0) * 0x811C9DC5) ^ UInt64($1.asciiValue!) }) }
}


@Observable public class Libre3: Libre {


    enum State: UInt8, CustomStringConvertible {
        case manufacturing      = 0

        /// packaged, not activated yet
        case storage            = 1

        case insertionDetection = 2
        case insertionFailed    = 3

        /// advertising via BLE already 5/10 minutes after activation
        case paired             = 4

        /// if Trident is not run on the final day, still advertising for further 24 hours
        case expired            = 5

        /// Trident sent the shutdown command as soon as run on the final day or
        /// the sensor stopped advertising via BLE by itself on the following day anyway
        case terminated         = 6

        case error              = 7

        /// detected for a detached sensor
        case errorTerminated    = 8

        var description: String {
            switch self {
            case .manufacturing:      "Manufacturing"
            case .storage:            "Not activated"
            case .insertionDetection: "Insertion detection"
            case .insertionFailed:    "Insertion failed"
            case .paired:             "Paired"
            case .expired:            "Expired"
            case .terminated:         "Terminated"
            case .error:              "Error"
            case .errorTerminated:    "Terminated (error)"
            }
        }
    }


    enum Condition: Int, CustomStringConvertible {
        case ok      = 0
        case invalid = 1
        /// Early Signal Attenuation
        case esa     = 2

        var description: String {
            switch self {
            case .ok:      "OK"
            case .invalid: "invalid"
            case .esa:     "ESA"
            }
        }
    }


    enum ProductType: Int, CustomStringConvertible {
        case others = 1
        case sensor = 4    // Libre 3's product family
        case lingo  = 9
        case instinct = 10 // Medtronic-branded Libre 3+ (firmware 1.4, generation 1)

        var description: String {
            switch self {
            case .others:   "others"  // OTHERS
            case .sensor:   "sensor"  // SENSOR
            case .lingo:    "Lingo"
            case .instinct: "Instinct"
            }
        }
    }


    enum ResultRange: Int, CustomStringConvertible {
        case `in`    = 0
        case below   = 1
        case above   = 2
        case noRange = 3

        var description: String {
            switch self {
            case .in:      "in range"
            case .below:   "below range"
            case .above:   "above range"
            case .noRange: "no range"
            }
        }
    }


    public enum PacketType: UInt8 {
        case controlCommand   = 0
        case controlResponse  = 1
        case patchStatus      = 2
        case currentGlucose   = 3
        case backfillHistoric = 4
        case backfillClinical = 5
        case eventLog         = 6
        case factoryData      = 7

        var description: String {
            switch self {
            case .controlCommand:   "control command"
            case .controlResponse:  "control response"
            case .patchStatus:      "patch status"
            case .currentGlucose:   "current glucose"
            case .backfillHistoric: "backfill historical"
            case .backfillClinical: "backfill clinical"
            case .eventLog:         "event log"
            case .factoryData:      "factory data"
            }
        }
    }

    static let packetDescriptors: [[UInt8]] = [
        [0x00, 0x00, 0x00],
        [0x00, 0x00, 0x0F],
        [0x00, 0x00, 0xF0],
        [0x00, 0x0F, 0x00],
        [0x00, 0xF0, 0x00],
        [0x0F, 0x00, 0x00],
        [0xF0, 0x00, 0x00],
        [0x44, 0x00, 0x00]
    ]


    enum UUID: String, CustomStringConvertible, CaseIterable {

        case data             = "089810CC-EF89-11E9-81B4-2A2AE2DBCCE4"
        case patchControl     = "08981338-EF89-11E9-81B4-2A2AE2DBCCE4"
        case patchStatus      = "08981482-EF89-11E9-81B4-2A2AE2DBCCE4"
        case oneMinuteReading = "0898177A-EF89-11E9-81B4-2A2AE2DBCCE4"
        case historicalData   = "0898195A-EF89-11E9-81B4-2A2AE2DBCCE4"
        case clinicalData     = "08981AB8-EF89-11E9-81B4-2A2AE2DBCCE4"
        case eventLog         = "08981BEE-EF89-11E9-81B4-2A2AE2DBCCE4"
        case factoryData      = "08981D24-EF89-11E9-81B4-2A2AE2DBCCE4"

        case security         = "0898203A-EF89-11E9-81B4-2A2AE2DBCCE4"
        case securityCommands = "08982198-EF89-11E9-81B4-2A2AE2DBCCE4"
        case challengeData    = "089822CE-EF89-11E9-81B4-2A2AE2DBCCE4"
        case certificateData  = "089823FA-EF89-11E9-81B4-2A2AE2DBCCE4"

        case debug            = "08982400-EF89-11E9-81B4-2A2AE2DBCCE4"
        case bleLogin         = "F001"

        var description: String {
            switch self {
            case .data:             "data service"
            case .patchControl:     "patch control"
            case .patchStatus:      "patch status"
            case .oneMinuteReading: "one-minute reading"
            case .historicalData:   "historical data"
            case .clinicalData:     "clinical data"
            case .eventLog:         "event log"
            case .factoryData:      "factory data"
            case .security:         "security service"
            case .securityCommands: "security commands"
            case .challengeData:    "challenge data"
            case .certificateData:  "certificate data"
            case .debug:            "debug service"
            case .bleLogin:         "BLE login"
            }
        }
    }

    class var knownUUIDs: [String] { UUID.allCases.map(\.rawValue) }


    // CMD_ECDH_START              = 0x01
    // CMD_LOAD_CERT_DATA          = 0x02
    // CMD_LOAD_CERT_DONE          = 0x03
    // CMD_CERT_ACCEPTED           = 0x04
    // CMD_AUTHORIZED              = 0x05
    // CMD_AUTHORIZE_ECDSA         = 0x06
    // CMD_AUTHORIZATION_CHALLENGE = 0x07
    // CMD_CHALLENGE_LOAD_DONE     = 0x08
    // CMD_SEND_CERT               = 0x09
    // CMD_CERT_READY              = 0x0A
    // CMD_IV_AUTHENTICATED_SEND   = 0x0B
    // CMD_IV_READY                = 0x0C
    // CMD_KEY_AGREEMENT           = 0x0D
    // CMD_EPHEMERAL_LOAD_DONE     = 0x0E
    // CMD_EPHEMERAL_KEY_READY     = 0x0F
    // CMD_ECDH_COMPLETE           = 0x10
    // CMD_AUTHORIZE_SYMMETRIC     = 0x11
    // CMD_MODE_SWITCH             = 0x12
    // CMD_VERIFICATION_FAILURE    = 0x13


    // - maximum packet size is 20
    // - notified packets are prefixed by 00, 01, 02, ...
    // - written packets are prefixed by their payloads offsets 00 00, 12 00, 24 00, 36 00, ...
    // - data packets end in a sequential Int16: 01 00, 02 00, ...
    //
    // Connection:
    // enable notifications for 2198, 23FA and 22CE
    // write  2198  11
    // notify 2198  08 17
    // notify 22CE  20 + 5 bytes        // 23-byte challenge
    // write  22CE  20 * 2 + 6 bytes    // 40-byte challenge response
    // write  2198  08
    // notify 2198  08 43
    // notify 22CE  20 * 3 + 11 bytes   // 67-byte encrypted kAuth
    // enable notifications for 1338, 1BEE, 195A, 1AB8, 1D24, 1482
    // notify 1482  18-byte packets     // patch status
    // enable notifications for 177A
    // write  1338  13 bytes            // command ending in 01 00
    // notify 177A  15 + 20 bytes       // one-minute reading
    // notify 195A  20-byte packets     // historical data
    // notify 1338  10 bytes            // ending in 01 00
    // write  1338  13 bytes            // command ending in 02 00
    // notify 1AB8  20-byte packets     // clinical data
    // notify 1338  10 bytes            // ending in 02 00
    //
    // Activation:
    // enable notifications for 2198, 23FA and 22CE
    // write  2198  01
    // write  2198  02
    // write  23FA  20 * 9 bytes        // 162-byte fixed certificate data
    // write  2198  03
    // notify 2198  04                  // certificate accepted event
    // write  2198  09
    // notify 2198  0A 8C               // certificate ready event
    // notify 23FA  20 * 7 + 8 bytes    // 140-byte patch certificate
    // write  2198  0D
    // write  23FA  20 * 3 + 13 bytes   // 65-byte ephemeral key
    // write  2198  0E
    // notify 2198  0F 41               // ephemeral ready event
    // notify 23FA  20 * 3 + 9 bytes    // 65-byte ephemeral key
    // write  2198  11
    // notify 2198  08 17
    // notify 22CE  20 + 5 bytes        // 23-byte challenge
    // write  22CE  20 * 2 + 6 bytes    // 40-byte challenge response
    // write  2198  08
    // notify 2198  08 43
    // notify 22CE  20 * 3 + 11 bytes   // 67-byte encrypted kAuth
    // enable notifications for 1338, 1BEE, 195A, 1AB8, 1D24, 1482
    // notify 1482  18 bytes            // patch status
    // enable notifications for 177A
    // write  1338  13 bytes            // command ending in 01 00
    // notify 1BEE  20 + 20 bytes       // event log
    // notify 1338  10 bytes            // ending in 01 00
    // write  1338  13 bytes            // command ending in 02 00
    // notify 1D24  20 * 11 + 12 bytes  // factory data (with latest firmwares, otherwise 10/11 varying packets)
    //                                  // 20 * 10 + 17 bytes when reactivating
    // notify 1338  10 bytes            // ending in 02 00
    //
    // Shutdown:
    // write  1338  13 bytes            // command ending in 03 00
    // notify 1BEE  20 bytes            // event log
    // notify 1338  10 bytes            // ending in 03 00
    // write  1338  13 bytes            // command ending in 04 00


    enum SecurityCommand: UInt8, CustomStringConvertible {

        case startECDH           = 0x01
        case loadCertificate     = 0x02
        case certificateLoadDone = 0x03
        case challengeLoadDone   = 0x08
        case sendCertificate     = 0x09
        case keyAgreement        = 0x0D
        case ephemeralLoadDone   = 0x0E
        case authorizeSymmetric  = 0x11

        var description: String {
            switch self {
            case .startECDH:           "start ECDH"
            case .loadCertificate:     "load certificate"
            case .certificateLoadDone: "certificate load done"
            case .challengeLoadDone:   "challenge load done"
            case .sendCertificate:     "send certificate"
            case .keyAgreement:        "key agreement"
            case .ephemeralLoadDone:   "ephemeral load done"
            case .authorizeSymmetric:  "authorize symmetric"
            }
        }
    }

    enum SecurityEvent: UInt8, CustomStringConvertible {

        case unknown             = 0x00
        case certificateAccepted = 0x04
        case challengeLoadDone   = 0x08
        case certificateReady    = 0x0A
        case ephemeralReady      = 0x0F

        var description: String {
            switch self {
            case .unknown:             "unknown [TODO]"
            case .certificateAccepted: "certificate accepted"
            case .challengeLoadDone:   "challenge load done"
            case .certificateReady:    "certificate ready"
            case .ephemeralReady:      "ephemeral ready"
            }
        }
    }


    struct EventLogEvent {
        let index: UInt8
        let lifeCount: UInt16
        let errorData: UInt16
        let eventData: UInt16
    }

    typealias PatchErrorEvent = EventLogEvent

    struct PatchStatusEvent {
        let state: State
        let lifeCount: UInt16
        let stackDisconnectReason: UInt8
        let appDisconnectReason: UInt8
        let errorEvent: PatchErrorEvent
    }


    enum ControlCommandArgRecordType: UInt8 {
        case historical = 0x00
        case clinical   = 0x01
    }
    enum ControlCommandArgRecordOrder: UInt8 {
        case descending = 0x00
        case ascending  = 0x01
    }
    enum ControlCommand: UInt8, CustomStringConvertible {
        /// - 010001 EC2C 0000 requests historical data from lifeCount 0x2CEC
        /// - 010101 9B48 0000 requests clinical data from lifeCount 0x489B
        case backfill      = 0x01

        case backfillRange = 0x02

        // TODO: test
        case abortBackfill = 0x03

        /// - 040100 0000 0000 requests event log from index 01
        case eventLog      = 0x04

        case shutdownPatch = 0x05

        case factoryData   = 0x06

        var description: String {
            switch self {
            case .backfill:      "backfill"
            case .backfillRange: "backfill range"
            case .abortBackfill: "abort backfill"
            case .eventLog:      "event log"
            case .shutdownPatch: "shutdown patch"
            case .factoryData:   "factory data"
            }
        }
    }

    var receiverId: UInt32 = 0  // fnv32Hash of LibreView GUID string

    var blePIN: Data = Data()   // 4 bytes returned by the activation command

    var buffer: Data = Data()
    var currentBufferPacketType: PacketType?

    var currentControlCommand:  ControlCommand?
    var controlCommandsQueue = [Data]()

    var currentSecurityCommand: SecurityCommand?
    var lastSecurityEvent: SecurityEvent = .unknown
    var expectedStreamSize = 0

    var patchCertificate: PatchCertificate?  // 140 bytes, includes patchStaticPublicKey
    var patchEphemeral: Data = Data()  // 65-byte uncompressed P-256

    var ephemeralPrivateKey: P256.KeyAgreement.PrivateKey = .init()
    var ephemeralPublicKey: Data = Data() // 65-byte uncompressed P-256 set by initECDH()
    var nativeEphemeral: FirstPairNativeEphemeralMaterial? // set by initECDH() when using LibreCRKit

    // FIXME: cannot work because we sent the app static public key with the app certificate
    var appStaticPrivateKey: P256.KeyAgreement.PrivateKey = .init()  // used when trying a new ECDH session

    var exportedKAuth: Data = Data() // 149-byte persistent SKB wrapped exported blob, includes encoded appStaticPrivateKey

    var sharedKey: Data = Data()  // 16-byte first-pair ECDH shared secret
    var outCryptoSequence: UInt16 = 1
    var kEnc: Data = Data()  // 16-byte session key
    var ivEnc: Data = Data() // 8 bytes
    // Challenge nonces stored during the security handshake
    var r1: Data = Data()     // 16 bytes from sensor challenge
    var r2: Data = Data()     // 16 random bytes generated locally
    var nonce1: Data = Data() //  7 bytes from sensor challenge

    var securityVersion: Int = 1

    var lastLifeCount: Int = 0
    var lastHistoricalLifeCount: Int = 0
    var lastHistoricalReadingDate: Date = .distantPast

    var lastPatchStatusEvent: PatchStatusEvent?
    var eventLog = [EventLogEvent]()


    func parsePatchInfo() {

        let productType = Int(patchInfo[12])
        type = [4: SensorType.libre3, 9: SensorType.lingo][productType] ?? .libre3
        log("\(type): product type: \(ProductType(rawValue: productType)?.description ?? "unknown") (0x\(productType.hex))")

        let securityVersion = UInt16(patchInfo[0...1])
        let localization    = UInt16(patchInfo[2...3])  // 1: Europe, 2: US
        let generation      = UInt16(patchInfo[4...5])  // 0: Libre 3, 1: Libre 3+, Instinct
        log("\(type): security version: \(securityVersion) (0x\(securityVersion.hex)), localization: \(localization) (0x\(localization.hex)), generation: \(generation) (0x\(generation.hex))")

        self.securityVersion = Int(securityVersion)
        self.generation = Int(generation)

        region = SensorRegion(rawValue: Int(localization & 0xFF)) ?? .unknown
        let subregion = UInt8((localization & 0xFF00) >> 8)
        // TODO: "market level"
        if subregion != 0 {
            type = .libreSelect
            if subregion == 0xC0 {
                log("\(type): subregion: France (0x\(subregion.hex))")
            }
        }

        let wearDuration = patchInfo[6...7]
        maxLife = Int(UInt16(wearDuration))
        settings.activeSensorMaxLife = maxLife
        log("\(type): wear duration: \(maxLife) minutes (\(maxLife.formattedInterval), 0x\(maxLife.hex))")

        let fwVersion = patchInfo.subdata(in: 8 ..< 12)
        firmware = "\(fwVersion[3]).\(fwVersion[2]).\(fwVersion[1]).\(fwVersion[0])"
        log("\(type): firmware version: \(firmware)")

        let warmupTime = patchInfo[13]
        log("\(type): warmup time: \(warmupTime * 5) minutes (0x\(warmupTime.hex) * 5)")

        let sensorState = patchInfo[14]
        // TODO: manage specific Libre 3 states
        state = SensorState(rawValue: sensorState <= 2 ? sensorState: sensorState - 1) ?? .unknown
        log("\(type): specific state: \(State(rawValue: sensorState)!.description.lowercased()) (0x\(sensorState.hex)), state: \(state.description.lowercased()) ")

        let serialNumber = Data(patchInfo[15...23])
        // prepend `9` family to a Lingo serial and `4` to a Libre Select serial
        serial = (productType == 9 ? "9" : type == .libreSelect ? "4" : "") + serialNumber.string
        log("\(type): serial number: \(serial) (0x\(serialNumber.hex))")

    }


    func send(securityCommand cmd: SecurityCommand) {
        log("Bluetooth: sending to \(typeAndName) `\(cmd.description)` command 0x\(cmd.rawValue.hex)")
        currentSecurityCommand = cmd
        transmitter!.write(Data([cmd.rawValue]), for: UUID.securityCommands.rawValue, .withResponse)
    }


    func send(
        controlCommand cmd: ControlCommand,
        type: ControlCommandArgRecordType? = nil,
        order: ControlCommandArgRecordOrder? = nil,
        args: Data? = nil
    ) {
        var command = cmd.rawValue.data
        if let type  { command.append(type.rawValue) }
        if let order { command.append(order.rawValue) }
        if let args  { command.append(args) }
        controlCommandsQueue.append(command)
        if controlCommandsQueue.count == 1 {
            let encryptedCommand = encryptPacket(data: command + Data(count: 7 - command.count), type: .controlCommand, ivEnc: ivEnc, sequenceId: outCryptoSequence)!
            log("Bluetooth: sending to \(typeAndName) `\(cmd.description)` control command \(command.hex) (encrypted: \(encryptedCommand.hex)), queue id: \(outCryptoSequence.data.hex)")
            transmitter!.write(encryptedCommand + outCryptoSequence.data, for: UUID.patchControl.rawValue, .withResponse)
            currentControlCommand = cmd
        }
    }


    func parsePackets(_ data: Data) -> (Data, String) {
        var payload = Data()
        var str = ""
        var offset = data.startIndex
        var offsetEnd = offset
        let endIndex = data.endIndex
        while offset < endIndex {
            str += data[offset].hex + "  "
            _ = data.formIndex(&offsetEnd, offsetBy: 20, limitedBy: endIndex)
            str += data[offset + 1 ..< offsetEnd].hexBytes
            payload += data[offset + 1 ..< offsetEnd]
            _ = data.formIndex(&offset, offsetBy: 20, limitedBy: endIndex)
            if offset < endIndex { str += "\n" }
        }
        return (payload, str)
    }


    func write(_ data: Data, for uuid: UUID = .challengeData) {
        let packetCount = (data.count - 1) / 18 + 1
        for i in 0 ..< packetCount {
            let offset = UInt16(i * 18)
            let packet = offset.data + data[offset ... min(offset + 17, UInt16(data.count - 1))]
            debugLog("Bluetooth: writing packet \(packet.hexBytes) to \(typeAndName)'s \(uuid.description) characteristic")
            transmitter!.write(packet, for: uuid.rawValue, .withResponse)
        }
    }


    struct PatchCertificate {
        let header: Data                // 11 bytes: lead 01 + 8-byte sensorUid + 2 trailing bytes
        let patchStaticPublicKey: Data  // 65 bytes uncompressed P-256 public key
        let signature: Data             // 64 bytes P-256 ECDSA signature of the previous 76 bytes

        init(data: Data, signingPublicKey: Data) {
            header = data.subdata(in: 0 ..< 11)
            patchStaticPublicKey = data.subdata(in: 11 ..< 76)
            signature = data.subdata(in: 76 ..< 140)
        }

        // [FSOpenSSL verifyECDSA:rawData:rsSignature:]
        func verifyECDSA(with signingPublicKey: Data) throws -> Bool {
            let publicKey = try P256.Signing.PublicKey(x963Representation: signingPublicKey)
            let ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            let signedPayload = header + patchStaticPublicKey
            return publicKey.isValidSignature(ecdsaSignature, for: signedPayload)
        }
    }


    /// called by Abbott Transmitter class
    func read(_ data: Data, for uuid: String) {

        switch UUID(rawValue: uuid) {

        case .patchControl:

            if data.count == 10 {

                let queueId = data.suffix(2)
                // TODO: manage enqueued id
                log("\(typeAndName): received \(data.count) bytes of patch control command data: \(data.hex), command queue id: \(queueId.hex)")
                if let controlResponse = decryptPacket(data: data, type: .controlResponse, ivEnc: ivEnc) {
                    log("\(typeAndName): decrypted control response: \(controlResponse.hex), command opcode: \(controlResponse[0]) (\(ControlCommand(rawValue: controlResponse[0])!))")
                } else {
                    log("\(typeAndName): FAILED to decrypt control response")
                }

                if buffer.count > 0 {

                    let uuids: [PacketType: Libre3.UUID] = [
                        .backfillHistoric: .historicalData,
                        .backfillClinical: .clinicalData,
                        .eventLog:         .eventLog,
                        .factoryData:      .factoryData
                    ]

                    let uuidDescription = uuids[currentBufferPacketType!]!.description

                    if queueId == "0100".bytes && currentBufferPacketType == nil {
                        currentBufferPacketType = .backfillHistoric
                    } else if queueId == "0200".bytes && currentBufferPacketType == nil {
                        currentBufferPacketType = .backfillClinical
                    }

                    var packets = [Data]()
                    for i in 0 ..< (buffer.count + 19) / 20 {
                        packets.append(Data(buffer[i * 20 ... min(i * 20 + 19, buffer.count - 1)]))
                    }

                    // TODO: factory data
                    // when reactivating a sensor received 20 * 10 + 17 bytes
                    // otherwise receiving 20 * 11 + 12 bytes with the latest firmwares
                    if buffer.count == 217 || buffer.count == 232 {
                        log("\(typeAndName): received \(packets.count) packets of factory data (\(buffer.count) bytes), payload: \(Data(packets.joined()).hexBytes)")
                    } else {
                        log("\(typeAndName): received \(packets.count) packets of \(uuidDescription)")
                    }

                    var decryptedPackets = [Data]()
                    for packet in packets {

                        debugLog("\(typeAndName): decrypting \(uuidDescription) packet: \(packet.hex) (\(packet.count) bytes), type: \(currentBufferPacketType!), kEnc: '\(kEnc.hex)', ivEnc: '\(ivEnc.hex)'")
                        if let decryptedPacket = decryptPacket(data: packet, type: currentBufferPacketType!, ivEnc: ivEnc) {
                            log("\(typeAndName): decrypted \(uuidDescription) packet: \(decryptedPacket.hex) (\(decryptedPacket.count) bytes)")
                            decryptedPackets.append(decryptedPacket)
                        } else {
                            log("\(typeAndName): FAILED to decrypt \(uuidDescription)")
                            break
                        }
                    }

                    if decryptedPackets.count > 0 {

                        switch currentBufferPacketType! {
                        case .backfillHistoric: parseHistoricalPackets(data: decryptedPackets)
                        case .backfillClinical: parseClinicalPackets(data: decryptedPackets)
                        case .eventLog:         parseEventLogPackets(data: decryptedPackets)
                        case .factoryData:      parseFactoryDataPackets(data: decryptedPackets)
                        default:
                            break
                        }

                        controlCommandsQueue.removeFirst()
                        if !controlCommandsQueue.isEmpty {
                            let command = controlCommandsQueue.first!
                            let cmd = ControlCommand(rawValue: command[0])!
                            outCryptoSequence += 1
                            let encryptedCommand = encryptPacket(data: command + Data(count: 7 - command.count), type: .controlCommand, ivEnc: ivEnc, sequenceId: outCryptoSequence)!
                            log("Bluetooth: sending to \(typeAndName) `\(cmd.description)` control command \(command.hex) (encrypted: \(encryptedCommand.hex)), queue id: \(outCryptoSequence.data.hex)")
                            transmitter!.write(encryptedCommand + outCryptoSequence.data, for: UUID.patchControl.rawValue, .withResponse)
                            currentControlCommand = cmd
                        } else {
                            currentControlCommand = nil
                        }
                    }

                    buffer = Data()
                    currentBufferPacketType = nil

                }
            }


        case .patchStatus:
            if activationTime == 0 && settings.activeSensorActivationTime != 0 {
                activationTime = UInt32(settings.activeSensorActivationTime)
                age = Int(Date().timeIntervalSince(Date(timeIntervalSince1970: Double(activationTime)))) / 60
            }
            let payload = data.prefix(16)
            let seqId = UInt16(data.suffix(2))
            log("\(typeAndName): received \(data.count) bytes of \(UUID(rawValue: uuid)!) (payload: \(payload.count) bytes): \(payload.hex), sequential id: \(seqId.hex)")
            debugLog("\(typeAndName): decrypting patch status: \(data.hex) (\(data.count) bytes), kEnc: '\(kEnc.hex)', ivEnc: '\(ivEnc.hex)'")
            if let patchStatus = decryptPacket(data: data, type: .patchStatus, ivEnc: ivEnc) {
                log("\(typeAndName): decrypted patch status: \(patchStatus.hex)")
                if patchStatus.count == 12 {
                    parsePatchStatus(data: patchStatus)
                }
            } else {
                log("\(typeAndName): FAILED to decrypt patch status")
            }
            log("\(typeAndName): enabling notifications on the one-minute reading characteristic")
            transmitter!.peripheral?.setNotifyValue(true, for: transmitter!.characteristics[UUID.oneMinuteReading.rawValue]!)
            if settings.userLevel < .test {
                // TODO: still working on an expired sensor:
                // send(controlCommand: .eventLog, args: "01".bytes)
                //
                // Switch the status from 05 (.expired) to 06 (.terminated), stopping the sensor from advertising:
                // send(controlCommand: .shutdownPatch)
            }


        case .oneMinuteReading:
            if buffer.count == 0 {
                buffer = Data(data)
            } else {
                buffer += data
                if buffer.count == 35 {
                    let payload = buffer.prefix(33)
                    let seqId = UInt16(buffer.suffix(2))
                    log("\(typeAndName): received \(buffer.count) bytes of \(UUID(rawValue: uuid)!) (payload: \(payload.count) bytes): \(payload.hex), sequential id: \(seqId.hex)")
                    debugLog("\(typeAndName): decrypting one-minute reading: \(buffer.hex) (\(buffer.count) bytes), kEnc: '\(kEnc.hex)', ivEnc: '\(ivEnc.hex)'")
                    if let oneMinuteReading = decryptPacket(data: buffer, type: .currentGlucose, ivEnc: ivEnc) {
                        log("\(typeAndName): decrypted one-minute reading: \(oneMinuteReading.hex) (\(oneMinuteReading.count) bytes)")
                        if oneMinuteReading.count == 29 {
                            parseOneMinuteReading(data: oneMinuteReading)
                        }
                    } else {
                        log("\(typeAndName): FAILED to decrypt one-minute reading")
                        if settings.selectedService == .libreLinkUp {
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                await main.libreLinkUp?.reload()
                                settings.lastOnlineDate = app.lastReadingDate + 3
                            }
                        }
                    }
                    buffer = Data()
                }
            }


        case .historicalData, .clinicalData, .eventLog, .factoryData:
            if buffer.count == 0 {
                buffer = Data(data)
            } else {
                buffer += data
            }
            let payload = data.prefix(18)
            let seqId = UInt16(data.suffix(2))

            let packetTypes: [Libre3.UUID: PacketType] = [
                .historicalData: .backfillHistoric,
                .clinicalData:   .backfillClinical,
                .eventLog:       .eventLog,
                .factoryData:    .factoryData
            ]

            currentBufferPacketType = packetTypes[UUID(rawValue: uuid)!]!
            log("\(typeAndName): received \(data.count) bytes of \(UUID(rawValue: uuid)!) (payload: \(payload.count) bytes): \(payload.hex), sequential id: \(seqId.hex)")


        case .securityCommands:
            lastSecurityEvent = SecurityEvent(rawValue: data[0]) ?? .unknown
            log("\(typeAndName): security event: \(lastSecurityEvent)\(lastSecurityEvent == .unknown ? " (" + data[0].hex + ")" : "")")
            if data.count == 2 {
                expectedStreamSize = Int(data[1] + data[1] / 20 + 1)
                log("\(typeAndName): expected response size: \(expectedStreamSize) bytes (payload: \(data[1]) bytes)")
                if data[1] == 23 {         // challenge
                    currentSecurityCommand = .authorizeSymmetric
                } else if data[1] == 67 {  // encrypted kAuth
                    currentSecurityCommand = .challengeLoadDone
                } else if data[1] == 140 { // patchCertificate
                    currentSecurityCommand = .sendCertificate
                } else if data[1] == 65 { // patchEphemeral
                    currentSecurityCommand = .ephemeralLoadDone
                }
            }
            if currentSecurityCommand == .certificateLoadDone && lastSecurityEvent == .certificateAccepted {
                if settings.userLevel < .test { // not eavesdropping on Trident
                    send(securityCommand: .sendCertificate)
                }
            }


        case .challengeData, .certificateData:
            if buffer.count == 0 {
                buffer = Data(data)
            } else {
                buffer += data
            }

            if buffer.count == expectedStreamSize {

                let (payload, hexDump) = parsePackets(buffer)
                log("\(typeAndName): received \(buffer.count) bytes of \(UUID(rawValue: uuid)!) (payload: \(payload.count) bytes):\n\(hexDump)")

                switch currentSecurityCommand {

                case .sendCertificate:
                    log("\(typeAndName): patch certificate: \(payload.hex)")
                    if payload.count == 140 {
                        patchCertificate = PatchCertificate(data: payload, signingPublicKey: patchSigningKeys[securityVersion].bytes)
                        let sensorId = patchCertificate!.header.subdata(in: 1 ..< 9)
                        debugLog("\(typeAndName): parsed patch certificate, header: \(patchCertificate!.header.hex) (sensor id: \(sensorId.hex), current sensor uid: \(settings.currentSensorUid.hex)), patch static public key: \(patchCertificate!.patchStaticPublicKey.hex), signature: \(patchCertificate!.signature.hex)")
                        if (try? patchCertificate!.verifyECDSA(with: patchSigningKeys[securityVersion].bytes)) == true {
                            debugLog("\(typeAndName): patch certificate ECDSA signature verified")
                        } else {
                            debugLog("\(typeAndName): patch certificate ECDSA signature not verified")
                        }
                        if settings.userLevel < .test { // not eavesdropping on Trident
                            initECDH()
                            debugLog("\(typeAndName): sending security command 'key agreement' 0x0D")
                            send(securityCommand: .keyAgreement)
                            debugLog("\(typeAndName): sending generated 65-byte P-256 x9.63 ephemeral key 0x\(ephemeralPublicKey.hex)")
                            write(ephemeralPublicKey, for: .certificateData)
                            debugLog("\(typeAndName): sending security command 'ephemereal load done' 0x0E")
                            send(securityCommand: .ephemeralLoadDone)
                        }
                    }

                case .ephemeralLoadDone:
                    log("\(typeAndName): patch ephemeral: \(payload.hex)")
                    if payload.count == 65 {
                        patchEphemeral = payload
                        if settings.userLevel < .test { // not eavesdropping on Trident
                            Task { @MainActor in
                                do {
                                    log("\(typeAndName): computing shared key...")
                                    sharedKey = try await deriveSharedKey()
                                    settings.activeSensorSharedKey = sharedKey
                                    log("\(typeAndName): derived shared key: \(sharedKey.hex)")
                                    send(securityCommand: .authorizeSymmetric)
                                } catch {
                                    self.log("\(self.typeAndName): ERROR deriving shared key: \(error.localizedDescription)")
                                }
                            }
                        }
                    }


                case .authorizeSymmetric:

                    let seqId = UInt16(payload[16...17])
                    log("\(typeAndName): security challenge: \(payload.hex) (sequential id: \(seqId.hex))")

                    // Store as instance vars to be verified later when decrypting kAuth
                    r1     = Data(payload.prefix(16))
                    nonce1 = Data(payload.suffix(7))
                    debugLog("\(typeAndName): r1: \(r1.hex), nonce1: \(nonce1.hex)")

                    if settings.userLevel < .test { // not eavesdropping on Trident
                        if blePIN.isEmpty && !settings.activeSensorBlePIN.isEmpty {
                            blePIN = settings.activeSensorBlePIN
                            debugLog("\(typeAndName): restore saved active sensor's BLE PIN: \(blePIN.hex)")
                        }
                        if sharedKey.isEmpty && !settings.activeSensorSharedKey.isEmpty {
                            sharedKey = settings.activeSensorSharedKey
                            debugLog("\(typeAndName): restore saved active sensor's shared key: \(sharedKey.hex)")
                        }
                        if !blePIN.isEmpty && !sharedKey.isEmpty {
                            r2 = Data((0 ..< 16).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) })
                            debugLog("\(typeAndName): generated random r2: \(r2.hex)")
                            let challengeResponse = r1 + r2 + blePIN
                            if let encryptedResponse = aesEncrypt(
                                data: challengeResponse,
                                key: sharedKey,
                                nonce: nonce1
                            ) {
                                log("\(typeAndName): writing encrypted challenge response: \(encryptedResponse.hex) (\(encryptedResponse.count) bytes), plain (r1 + r2 + BLE PIN): \(challengeResponse.hex) (\(challengeResponse.count) bytes)")
                                write(encryptedResponse)
                                send(securityCommand: .challengeLoadDone)
                            } else {
                                log("\(typeAndName): FAILED to encrypt challenge response")
                            }
                        }
                        if blePIN.isEmpty {
                            log("\(typeAndName): BLE PIN unknown, need a NFC scan first")
                        }
                        if sharedKey.isEmpty {
                            log("\(typeAndName): shared key unknown, cannot proceed")
                        }
                    }


                case .challengeLoadDone:
                    let encryptedKAuth = payload.subdata(in:  0 ..< 60)
                    let nonce = payload.subdata(in: 60 ..< 67)
                    let seqId = UInt16(payload[60 ... 61])
                    log("\(typeAndName): encrypted kAuth: \(encryptedKAuth.hex), nonce: \(nonce.hex) (sequential id: \(seqId.hex))")
                    if let decryptedKAuth = aesDecrypt(
                        data: encryptedKAuth,
                        key: sharedKey,
                        nonce: nonce
                    ) {
                        let r2 = decryptedKAuth.subdata(in:  0 ..< 16)
                        let r1 = decryptedKAuth.subdata(in: 16 ..< 32)
                        kEnc   = decryptedKAuth.subdata(in: 32 ..< 48)
                        ivEnc  = decryptedKAuth.subdata(in: 48 ..< 56)
                        settings.activeSensorKEnc = kEnc
                        settings.activeSensorIvEnc = ivEnc
                        log("\(typeAndName): decrypted kAuth: r2: \(r2.hex) (sent: \(self.r2.hex)), r1: \(r1.hex) (sent: \(self.r1.hex)), kEnc: '\(kEnc.hex)', ivEnc: '\(ivEnc.hex)'")
                    } else {
                        log("\(typeAndName): FAILED to decrypt kAuth")
                    }
                    log("\(typeAndName): enabling notifications on the patch status characteristic")
                    transmitter!.peripheral?.setNotifyValue(true, for: transmitter!.characteristics[UUID.patchStatus.rawValue]!)
                    currentSecurityCommand = nil


                default:
                    break // currentSecurityCommand
                }

                buffer = Data()
                expectedStreamSize = 0

            }

        default:
            break  // uuid
        }

    }


    func parsePatchStatus(data: Data) {
        let eventLifeCount = UInt16(data[0...1])
        let eventDate = Date(timeIntervalSince1970: Double(activationTime + UInt32(eventLifeCount) * 60))
        let errorData = UInt16(data[2...3])
        let eventData = UInt16(data[4...5])  // TODO: add 4000
        let index = data[6]
        let state = Libre3.State(rawValue: data[7])!
        let lifeCount = UInt16(data[8...9])
        age = Int(lifeCount)
        activationTime = UInt32(Date.now.timeIntervalSince1970) - 60 * UInt32(lifeCount)
        let date = Date(timeIntervalSince1970: Double(activationTime + UInt32(lifeCount) * 60))
        let stackDisconnectReason = data[10]
        let appDisconnectReason = data[11]
        lastPatchStatusEvent = PatchStatusEvent(state: state, lifeCount: lifeCount, stackDisconnectReason: stackDisconnectReason, appDisconnectReason: appDisconnectReason, errorEvent: PatchErrorEvent(index: index, lifeCount: eventLifeCount, errorData: errorData, eventData: eventData))
        log("\(typeAndName): parsed patch status: state: \(state) (0x\(data[7].hex)), life count: \(lifeCount) (0x\(lifeCount.hex)), date: \(date.local), stack disconnect reason: \(stackDisconnectReason) (0x\(stackDisconnectReason.hex), app disconnect reason: \(appDisconnectReason) (0x\(appDisconnectReason.hex)), last event index: \(index) (0x\(data[6].hex)), event life count: \(eventLifeCount) (0x\(eventLifeCount.hex)), event date: \(eventDate.local), event error data: \(errorData) (0x\(data[2...3].hex)), event data: \(eventData) (0x\(data[4...5].hex))")
    }


    func parseOneMinuteReading(data: Data) {
        let lifeCount = UInt16(data[0...1])
        age = Int(lifeCount)
        let date = Date(timeIntervalSince1970: Double(activationTime + UInt32(lifeCount) * 60))
        let readingMgDl = UInt16(data[2...3])
        let dataQuality = (readingMgDl & 0xE000) // upper 3 bits
        let dqErrorFlag = readingMgDl & 0x8000 != 0  // MSB
        // TODO: HI = 0x4000, RF = 0x8020, TOO_HOT = 0xA000, TOO_COLD = 0xC000
        var glucose = Int(readingMgDl & 0x1fff)
        let rateOfChangeInt16 = Int16(bitPattern: UInt16(data[4...5]))
        let rateOfChange = rateOfChangeInt16 != Int16.min ? Double(rateOfChangeInt16) / 100.0 : 0.0
        let esaDuration = UInt16(data[6...7])
        let projectedGlucose = UInt16(data[8...9]) / 100  // TODO: 0xFFFF
        let historicalLifeCount = UInt16(data[10...11])
        let historicalDate = Date(timeIntervalSince1970: Double(activationTime + UInt32(historicalLifeCount) * 60))
        let historicalReadingMgDl = UInt16(data[12...13])
        let historicalGlucose = Int(historicalReadingMgDl & 0x1fff)
        // TODO:
        let bitfields = data[14]
        let trend = bitfields & 0x07 // lower 3 bits
        let trendArrow = TrendArrow(rawValue: Int(trend))!
        let actionableFlag = (bitfields & 0x08) !=  0
        let statusBits = bitfields >> 4 // upper 4 bits
        let uncappedCurrentMgDl = UInt16(data[15...16])
        let uncappedHistoricMgDl = UInt16(data[17...18])
        let temperature = Double(UInt16(data[19...20])) / 100.0
        let fastData = data.subdata(in: 21 ..< 29)

        log("\(typeAndName): parsed one-minute reading: life count: \(lifeCount) (0x\(lifeCount.hex)), date: \(date.local), glucose: \(glucose) mg/dL (0x\(readingMgDl.hex) & 0x1fff), data quality: 0x\(dataQuality.hex), data quality error flag: \(dqErrorFlag), rate of change: \(rateOfChange) mg/dL/min (0x\(data[4...5].hex)), bitfields: 0x\(bitfields.hex), trend: \(trendArrow) \(trendArrow.symbol) (0x\(trend.hex)), actionable flag: \(actionableFlag), status bits: 0x\(statusBits.hex), temperature: \(temperature)°C (0x\(data[19...20].hex)/100), historical life count: \(historicalLifeCount) (0x\(historicalLifeCount.hex)), historical date: \(historicalDate.local), historical glucose: \(historicalGlucose) mg/dL (0x\(historicalReadingMgDl.hex) & 0x1fff)")
        log("\(typeAndName): parsed one-minute further data: Early Signal Attenuation duration: \(esaDuration) minutes (0x\(data[6...7].hex)), projected glucose: \(projectedGlucose) mg/dL (0x\(data[8...9].hex)/100), uncapped current glucose: \(uncappedCurrentMgDl) mg/dL (0x\(uncappedCurrentMgDl.hex)), uncapped historical glucose: \(uncappedHistoricMgDl) mg/dL (0x\(uncappedHistoricMgDl.hex)), raw fast data: \(fastData.hex)")

        if dqErrorFlag { glucose = -glucose } // TODO: mark as invalid, i. e. 0x8020 RF interference error when scanning
        lastHistoricalLifeCount = Int(historicalLifeCount)
        lastLifeCount = Int(lifeCount)
        settings.activeSensorLastLifeCount = lastLifeCount
        lastReadingDate = date
        main.app.lastReadingDate = date
        main.app.currentGlucose = glucose
        main.app.trendArrow = trendArrow
        main.app.trendDelta = rateOfChange
        main.app.trendDeltaMinutes = 1
        // TODO: data quality
        self.trend.insert(Glucose(glucose, id: Int(lifeCount), date: date, dataQuality: Glucose.DataQuality(rawValue: Int(dataQuality))), at: 0)
        if self.trend.count > 17 + 5 { // latency + current historical timestamp
            self.trend.removeLast(self.trend.count - (17 + 5))
        }
        main.history.factoryTrend = self.trend
        // TODO: fill the gaps when reconnecting
        if !history.isEmpty {
            if lastHistoricalLifeCount == history[0].id + 5 {
                // TODO: data quality
                history.insert(Glucose(Int(historicalGlucose), id: lastHistoricalLifeCount, date: historicalDate), at: 0)
                if history.count > 12 * 12 {
                    history.removeLast(history.count - 12 * 12)
                }
                main.history.factoryValues = history
            }
            main.didParseSensor(self)
        } else {
            // backfill 12 hours of historical data:
            send(controlCommand: .backfill, type: .historical, order: .ascending, args: UInt16(max(Int16(historicalLifeCount) - (12 * 12 - 1) * 5, 5)).data)
        }
    }


    func parseHistoricalPackets(data: [Data]) {
        log("\(typeAndName): \(data.count) backfill historical data packets: \(data.map { $0.hex })")
        var history = [Glucose]()
        for data in data {
            let startLifeCount = UInt16(data[0...1])
            let date = Date(timeIntervalSince1970: Double(activationTime + UInt32(startLifeCount) * 60))
            var readings = [(lifeCount: UInt16, date: Date, glucose: Int, range: ResultRange, dqErrorFlag: Bool)]()
            for i in 0 ... 5 {
                let lifeCount = startLifeCount + UInt16(i * 5)
                let readingMgDl = UInt16(data[(i * 2 + 2) ... (i * 2 + 3)])
                let dataQuality = readingMgDl & 0x8000
                let dqErrorFlag = readingMgDl & 0x8000 != 0
                let date = Date(timeIntervalSince1970: Double(activationTime + UInt32(lifeCount) * 60))
                var glucose = Int(readingMgDl & 0x1fff)
                // TODO: not range but data quality flags 0xE000?
                let resultRange = ResultRange(rawValue: Int((readingMgDl & 6000) >> 13))!
                let entry = (lifeCount: lifeCount, date: date, glucose: glucose, range: resultRange, dqErrorFlag: dqErrorFlag)
                readings.append(entry)
                // TODO: data quality
                if dqErrorFlag { glucose = -glucose } // TODO: mark as invalid
                if glucose == 0 && !dqErrorFlag { continue }  // future zeros
                history.append(Glucose(glucose, id: Int(lifeCount), date: date, dataQuality: Glucose.DataQuality(rawValue: Int(dataQuality))))
            }
            log("\(typeAndName): parsed 6 backfill historical data: life count: \(startLifeCount) (0x\(startLifeCount.hex)), date: \(date.local), readings: \(readings.map { "life count: \($0.lifeCount), date: \($0.date.local), glucose: \($0.glucose), range: \($0.range), quality error flag: \($0.dqErrorFlag)" })")
        }
        self.history = history.reversed()
        main.history.factoryValues = self.history
        outCryptoSequence += 1
        send(controlCommand: .backfill, type: .clinical, order: .ascending, args: UInt16(lastHistoricalLifeCount + 1).data)
        main.didParseSensor(self)
    }


    func parseClinicalPackets(data: [Data]) {
        log("\(typeAndName): \(data.count) backfilled clinical data packets: \(data.map { $0.hex })")
        var trend = [Glucose]()
        for data in data {
            let lifeCount = UInt16(data[0...1])
            let date = Date(timeIntervalSince1970: Double(activationTime + UInt32(lifeCount) * 60))
            let rawData = data[2...9]  // first 6 bytes of 8 coming from the filament as for the Libre 1/2
            let readingMgDl = UInt16(data[10...11])
            let dqErrorFlag = readingMgDl & 0x8000 != 0
            var glucose = Int(readingMgDl & 0x1fff)
            if dqErrorFlag { glucose = -glucose } // TODO: mark as invalid
            let historicalLifeCount = UInt16(max(((Int16(lifeCount) - 17) / 5) * 5, 5)) // HISTORIC_POINT_LATENCY = 17
            let historicalDate = Date(timeIntervalSince1970: Double(activationTime + UInt32(historicalLifeCount) * 60))
            let historicMgDl = UInt16(data[12...13])
            let historicalGlucose = Int(historicMgDl & 0x1fff)
            log("\(typeAndName): parsed backfilled clinical data: life count: \(lifeCount) (0x\(lifeCount.hex)), date: \(date.local), raw data: \(rawData.hex),  glucose: \(glucose) mg/dL (0x\(readingMgDl.hex) & 0x1fff), data quality error flag: \(dqErrorFlag), historical life count: \(historicalLifeCount), historical date: \(historicalDate.local), historical glucose: \(historicalGlucose) mg/dL (0x\(historicMgDl.hex) & 0x1fff)")
            // TODO: data quality
            trend.append(Glucose(Int(glucose), id: Int(lifeCount), date: date))
        }
        self.trend = trend.reversed()
        main.history.factoryTrend = self.trend

        outCryptoSequence += 1
        send(controlCommand: .factoryData)
        // request event log from index 01:
        send(controlCommand: .eventLog, args: "01".bytes)
    }


    func parseEventLogPackets(data: [Data]) {
        log("\(typeAndName): \(data.count) event log packets: \(data.map { $0.hex })")
        eventLog = []
        for data in data {
            for i in 0...1 {
                let lifeCount = UInt16(data[(i * 7) ... (i * 7 + 1)])
                let errorData = UInt16(data[(i * 7 + 2) ... (i * 7 + 3)])
                let eventData = UInt16(data[(i * 7 + 4) ... (i * 7 + 5)])
                let index = data[i * 7 + 6]
                let event = EventLogEvent(index: index, lifeCount: lifeCount, errorData: errorData, eventData: eventData)
                eventLog.append(event)
            }
            debugLog("\(typeAndName): parsed 2 log events: \(eventLog.suffix(2).map { "index: \($0.index), life count: \($0.lifeCount) (0x\($0.lifeCount.hex)), date: \(Date(timeIntervalSince1970: Double(activationTime + UInt32($0.lifeCount) * 60)).local), error data: \($0.errorData), event data: \($0.eventData)" })")
        }
        var msg = "\(typeAndName): event log:"
        for event in eventLog {
            msg += "\n\(event.index). \(event.lifeCount.hex) \(Date(timeIntervalSince1970: Double(activationTime + UInt32(event.lifeCount) * 60)).local)\n"
            // TODO:
            let eventDescriptions: [UInt16: String] = [
                0x0D: "Reactivation (new BLE PIN)"
            ]
            if var state = Libre3.State(rawValue: UInt8(event.eventData))?.description {
                if state == "Insertion failed" { state = "Warming up" }  // TODO: state 3 error
                msg += "   \(event.eventData.hex): \(state)"
            } else if let eventDescription = eventDescriptions[event.eventData] {
                msg += "   \(event.eventData.hex): \(eventDescription)"
            } else {
                msg += "   \(event.eventData.hex)"
            }
            if event.errorData != 0 {
                msg += ", error: \(event.errorData.hex)"
            }
        }
        log(msg)
    }


    func parseFactoryDataPackets(data: [Data]) {
        var factoryData = Data()
        for data in data {
            factoryData.append(data.dropFirst())
        }
        log("\(typeAndName): \(factoryData.hexDump(header: "factory data: computed CRC: \(factoryData.dropLast(2).crc16.hex) (\(factoryData.count) bytes):"))")
        serial = factoryData.subdata(in: 74 ..< 84).string // TODO: family prefix
        settings.activeSensorSerial = serial
        uid = factoryData.subdata(in: 52 ..< 58) + "7AE0".bytes
        if uid == settings.currentSensorUid && !settings.currentPatchInfo.isEmpty {
            patchInfo = settings.currentPatchInfo
        }
        let aaDocString = factoryData.subdata(in: 86 ..< 98).string
        // TODO: '0100 0100' from patch info
        let wearDuration = factoryData.subdata(in: 102 ..< 104)
        maxLife = Int(UInt16(wearDuration))
        let aaTail = factoryData.subdata(in: 132 ..< 140)
        log("\(typeAndName): parsed factory data: serial number: \(serial), NFC uid: \(uid.hex), wear duration: \(maxLife) minutes (\(maxLife.formattedInterval), 0x\(maxLife.hex)), same as NFC 0xAA command output: \"\(aaDocString)\" + \(aaTail.hex)")
    }


    // CMD_ACTIVATE_SENSOR (0xA0) returns the current BLE PIN on an activated sensor,
    // the error 0x1B1 on a sensor activated by the reader, the error 0x1B2 on an
    // expired sensor with a firmware like 1.1.13.30 and a new BLE PIN with older
    // firmwares like 1.0.25.30...

    var activationNFCCommand: NFCCommand {
        if receiverId == 0 && settings.libreLinkUpUserId == "" {
            log("WARNING: the current receiverId and libreLinkUpUserId are null: a successful login to LibreLinkUp is very probably required first.")
        }
        var parameters: Data = Data()
        parameters += ((activationTime != 0 ? activationTime : UInt32(Date().timeIntervalSince1970)) - 1).data
        parameters += (receiverId != 0 ? receiverId : settings.libreLinkUpPatientId.fnv32Hash).data
        parameters += parameters.crc16.data

        return NFCCommand(code: 0xA0, parameters: parameters, description: "activate")
    }

    // NOTTODO: CMD_SWITCH_RECEIVER (0xA8): same input parameters and output as 0xA0 but it
    // changes the BLE PIN of an activated sensor; returns the error 0x1B0 on an expired one


    func parseActivation(output: Data) {

        let output = Data(output.drop(while: { $0 == 0xA5 }))
        let flag = output[0]
        let response = Data(output.dropFirst())

        if flag == 0x01 && response.count == 1 {
            log("NFC: \(type) activation response: error code 0x\(response.hex)")
            // getting 0xb0 / 0xb2 on an expired sensor
            // getting 0xb1 on a sensor activated by the reader
            // getting NFC error 0xc2 when altering crc16
            // getting NFC error 0xc1 when omitting crc16
        }

        if flag == 0x00 && response.count == 16 {
            let macAddress = Data(response[0 ..< 6].reversed())
            transmitter?.macAddress = macAddress
            blePIN = response.subdata(in: 6 ..< 10)
            settings.activeSensorBlePIN = blePIN
            activationTime = UInt32(response.subdata(in: 10 ..< 14))
            settings.activeSensorActivationTime = Int(activationTime)
            age = Int(Date().timeIntervalSince(Date(timeIntervalSince1970: Double(activationTime)))) / 60
            let crc = UInt16(response[14 ... 15])
            let computedCrc = response[0 ... 13].crc16
            log("NFC: \(type) activation response: BLE MAC address: \(macAddress.hexAddress), BLE PIN: \(blePIN.hex), activation date: \(Date(timeIntervalSince1970: Double(activationTime)).local), CRC: \(crc.hex), computed CRC: \(computedCrc.hex)")
        }
    }


    func pair() {
        send(securityCommand: .startECDH)
        send(securityCommand: .loadCertificate)
        let appCertificate = settings.usingLibreCRKit || settings.usingMessinaSharedKeyServer ? androidAppCertificates[securityVersion].bytes : appCertificates[securityVersion].bytes
        write(appCertificate, for: .certificateData)
        send(securityCommand: .certificateLoadDone)
        // TODO
        if settings.userLevel == .test {
            settings.userLevel = .devel  // let sending 0x09 to request patch certificate (CMD_SEND_CERT)
        }
    }


    // MARK: - Constants


    class Libre3BLESensor {
        static let STATE_NONE           = 0
        static let STATE_AUTHENTICATING = 5
        static let STATE_AUTHORIZING    = 8
        static let MAX_WRITE_OFFSET_DATA_LENGTH = 18
        static let HISTORIC_POINT_LATENCY = 17
    }


    enum SensorError: Int {
        case sensorTransmissionError = 0
        case sensorNotActive         = 1
        case sensorExpired           = 2
        case sensorInWarmup          = 3
        case sensorTerminated        = 4
        case sensorInsertionFailure  = 5
        case sensorNotCompatible     = 6
        case sensorRemoved           = 7
        case sensorAlreadyStarted    = 8
        case sensorTemporaryProblem  = 9
        case sensorHot               = 10
        case sensorCold              = 11
        case sensorResponseCorrupt   = 12
        case sensorESACheck          = 13
        case sensorNoError           = 14
    //  case sensorNotYours          = 15  // TODO: Android only?
        case invalidData             = 15
    }


    struct MSLibre3Constants {
        static let LIBRE3_HISTORIC_LIFECOUNT_INTERVAL = 5
        static let LIBRE3_MAX_HISTORIC_READING_IN_PACKET = 10
        static let LIBRE3_DQERROR_MAX = 0xFFFF
        static let LIBRE3_DQERROR_DQ              = 0x8000  // 32768
        static let LIBRE3_DQERROR_SENSOR_TOO_HOT  = 0xA000  // 40960
        static let LIBRE3_DQERROR_SENSOR_TOO_COLD = 0xC000  // 49152
        static let LIBRE3_DQERROR_OUTLIER_FILTER_DELTA = 2
    }


    class DPCRLInterface {
        static let ABT_NO_ERROR: Int = 0x0
        static let ABT_ERR0_BLE_TURNED_OFF: Int = 0x1f7
        static let ABT_ERR3_TIME_CHANGE: Int = 0x2e
        static let ABT_ERR3_SENSOR_EXPIRED: Int = 0x33
        static let ABT_ERR3_SENSOR_RSSI_ERROR: Int = 0x39
        static let ABT_ERR3_BLE_TURNED_OFF: Int = 0x4b
        static let ABT_ERR3_REPLACE_SENSOR_ERROR: Int = 0x16d
        static let ABT_ERR3_SENSOR_FALL_OUT_ERROR: Int = 0x16e
        static let ABT_ERR3_INCOMPATIBLE_SENSOR_TYPE_ERROR: Int = 0x16f
        static let ABT_ERR3_SENSOR_CAL_CODE_ERROR = 0x170
        static let ABT_ERR3_SENSOR_DYNAMIC_DATA_CRC_ERROR = 0x171
        static let ABT_ERR3_SENSOR_FACTORY_DATA_CRC_ERROR = 0x172
        static let ABT_ERR3_SENSOR_LOG_DATA_CRC_ERROR = 0x173
        static let ABT_ERR3_SENSOR_NOT_YOURS_ERROR: Int = 0x174
        static let ABT_ERR3_REALTIME_RESULT_DQ_ERROR: Int = 0x175
        static let ABT_ERR3_SENSOR_ESA_DETECTED: Int = 0x17c
        static let ABT_ERR3_SENSOR_NOT_IN_GLUCOSE_MEASUREMENT_STATE: Int = 0x181
        static let ABT_ERR3_BLE_PACKET_ERROR: Int = 0x182
        static let ABT_ERR3_INVALID_DATA_SIZE_ERROR: Int = 0x183
        static let ABT_ERR9_LIB_NOT_INITIALIZED_ERROR: Int = 0x3d6
        static let ABT_ERR9_MEMORY_SIZE_ERROR: Int = 0x3d7
        static let ABT_ERR9_NV_MEMORY_CRC_ERROR: Int = 0x3da
        static let ABT_ERR10_INVALID_USER: Int = 0x582
        static let ABT_ERR10_DUPLICATE_USER: Int = 0x596
        static let ABT_ERR10_INVALID_TOKEN: Int = 0x5a6
        static let ABT_ERR10_INVALID_DEVICE: Int = 0x5aa
        static let ABT_ERROR_DATA_BYTES = 0x8
        static let LIBRE3_DP_LIBRARY_PARSE_ERROR = ~0x0
        static let NFC_ACTIVATION_COMMAND_PAYLOAD_SIZE: Int = 10
        static let PATCH_CONTROL_BACKFILL_GREATER_SIZE = 11
        static let ABT_HISTORICAL_POINTS_PER_NOTIFICATION: Int = 6
        static let LIB3_RECORD_ORDER_NEWEST_TO_OLDEST: Int = 0
        static let LIB3_RECORD_ORDER_OLDEST_TO_NEWEST: Int = 1
        static let PATCH_CONTROL_COMMAND_SIZE: Int = 7
        static let PATCH_NFC_EVENT_LOG_NUM_EVENTS: Int = 3
        static let ABT_EVENT_LOGS_PER_NOTIFICATION: Int = 2
        static let SCRATCH_PAD_BUFFER_SIZE: Int = 0x400
        static let CRL_NV_MEMORY_SIZE: Int = 0x400
        static let LIBRE3_DEFAULT_WARMUP_TIME = 60
        static let MAX_SERIAL_NUMBER_SIZE = 15
        var lastError: Int = 0
        var scratchPadBuffer: UnsafeMutablePointer<UInt32>? = nil
    }


    // Android libre3SecurityConstants
    struct Libre3SecurityConstants {
        static let CERT_PATCH_DATE_STAMP_LENGTH: Int = 2
        static let CERT_PATCH_LENGTH: Int = 140
        static let CERT_PATCH_VERSION_LENGTH: Int = 1
        static let CERT_PUBLIC_KEY_LENGTH: Int = 65
        static let CERT_SERIAL_NUMBER_LENGTH: Int = 8
        static let CERT_SIGNATURE_LENGTH: Int = 64

        static let CMD_AUTHORIZATION_CHALLENGE: UInt8 = 0x07
        static let CMD_AUTHORIZED: UInt8 = 0x05
        static let CMD_AUTHORIZE_ECDSA: UInt8 = 0x06
        static let CMD_AUTHORIZE_SYMMETRIC: UInt8 = 0x11
        static let CMD_CERT_ACCEPTED: UInt8 = 0x04
        static let CMD_CERT_READY: UInt8 = 0x0A
        static let CMD_CHALLENGE_LOAD_DONE: UInt8 = 0x08
        static let CMD_ECDH_COMPLETE: UInt8 = 0x10
        static let CMD_ECDH_START: UInt8 = 0x01
        static let CMD_EPHEMERAL_KEY_READY: UInt8 = 0x0F
        static let CMD_EPHEMERAL_LOAD_DONE: UInt8 = 0x0E
        static let CMD_IV_AUTHENTICATED_SEND: UInt8 = 0x0B
        static let CMD_IV_READY: UInt8 = 0x0C
        static let CMD_KEY_AGREEMENT: UInt8 = 0x0D
        static let CMD_LOAD_CERT_DATA: UInt8 = 0x02
        static let CMD_LOAD_CERT_DONE: UInt8 = 0x03
        static let CMD_MODE_SWITCH: UInt8 = 0x12
        static let CMD_SEND_CERT: UInt8 = 0x09
        static let CMD_VERIFICATION_FAILURE: UInt8 = 0x13

        static let CRYPTO_KEY_LENGTH_BYTES: Int = 16
        static let CRYPTO_MAC_LENGTH_BYTES: Int = 4
        static let L3_SEC_ERROR_AUTHENTICATION_FAILED: Int = 902
        static let L3_SEC_ERROR_AUTHORIZATION_FAILED: Int = 903
        static let L3_SEC_ERROR_DECRYPTION_FAILED: Int = 904
        static let L3_SEC_ERROR_ENCRYPTION_FAILED: Int = 905
        static let L3_SEC_ERROR_INVALID_CERTIFICATE: Int = 901
        static let L3_SEC_ERROR_LIB_ERROR: Int = 906
    }

    // App certficates are indexed by the sensor security version (currently 1)
    //
    //  Claude:
    //
    //  18–19: keyUsage / curve marker: 0x00 0x01: likely "ECDSA P-256, app role"
    //  20–23: issuanceTimestamp: big-endian Unix seconds: V0: 0x5F149FE1 = 2020-07-19 19:32:49 UTC
    //                                                     V1: 0x61897655 = 2021-11-08 19:11:17 UTC
    //     24: receiverId flag: 0x01: set
    //  25–32: receiverId: all zeros for a generic account / pre-pairing (CERT_SERIAL_NUMBER_LENGTH = 8)
    //  33–97: appStaticPublicKey: 65-byte uncompressed P-256
    // 98–161: ECDSA signature: 64 bytes, raw r ‖ s signed with the `patchSigningKeys[v]` private counterpart

    // iOS Trident:
    let appCertificates = [
        "03 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 00 01 5F 14 9F E1 01 00 00 00 00 00 00 00 00 04 27 51 FD 1E F4 2B 14 5A 52 C5 93 AE 6B 5A 75 58 8A 9F 7E AF 1C 0F 99 85 F9 93 D5 8F 14 7B B8 41 68 42 24 49 96 37 92 DC 43 F3 84 47 EF EB BB EB 4A 53 B3 25 5C 0B E0 FE 1F 23 58 44 A3 D3 29 9E BA 97 B8 E6 C3 17 09 39 F2 77 8F 64 86 6F 06 6D EB 91 5D D6 62 9E EE 47 30 A1 E1 4C AB 75 C1 8C 4F EC 53 F8 85 4C 87 64 3A 76 4F 40 87 AE C0 39 4C 21 0C 18 86 5A 8F F4 5A DC 37 27 F4 8B 53 A7",
        "03 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 00 01 5F 14 9F E1 01 00 00 00 00 00 00 00 00 04 E2 36 95 4F FD 06 A2 25 22 57 FA A7 17 6A D9 0A 69 02 E6 1D DA FF 40 FB 36 B8 FB 52 AA 09 2C 33 A8 02 32 63 2E 94 AF A8 28 86 AE 75 CE F9 22 CD 88 85 CE 8C DA B5 3D AB 2A 4F 23 9B CB 17 C2 6C DE 74 9E A1 6F 75 89 76 04 98 9F DC B3 F0 C7 BC 1D A5 E6 54 1D C3 CE C6 3E 72 0C D9 B3 6A 7B 59 3C FC C5 65 D6 7F 1E E1 84 64 B9 B9 7C CF 06 BE D0 40 C7 BB D5 D2 2F 35 DF DB 44 58 AC 7C 46 15"
    ]

    let androidAppCertificates = [
        "03 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 00 01 5f 14 9f e1 01 00 00 00 00 00 00 00 00 04 27 51 fd 1e f4 2b 14 5a 52 c5 93 ae 6b 5a 75 58 8a 9f 7e af 1c 0f 99 85 f9 93 d5 8f 14 7b b8 41 68 42 24 49 96 37 92 dc 43 f3 84 47 ef eb bb eb 4a 53 b3 25 5c 0b e0 fe 1f 23 58 44 a3 d3 29 9e ba 97 b8 e6 c3 17 09 39 f2 77 8f 64 86 6f 06 6d eb 91 5d d6 62 9e ee 47 30 a1 e1 4c ab 75 c1 8c 4f ec 53 f8 85 4c 87 64 3a 76 4f 40 87 ae c0 39 4c 21 0c 18 86 5a 8f f4 5a dc 37 27 f4 8b 53 a7",
        "03 03 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 00 01 61 89 76 55 01 00 00 00 00 00 00 00 00 04 82 42 be 33 f1 a3 30 88 01 12 fa 62 cc 48 42 a4 3d 12 04 92 2a d2 01 d8 77 5b b2 26 f6 11 f7 5b 0e f3 d5 bc 6c c4 31 7c aa 45 75 84 ab 00 3f 17 12 33 60 89 d3 a4 f2 98 38 ed 0d c6 66 de ae a2 d6 5a 00 df ff 5d 7b ca e2 16 55 e3 02 e3 45 8e 77 4d aa aa ca 87 af 75 f1 b8 78 84 b1 8d 4c e8 75 d0 d1 08 c9 03 a8 34 47 1a 4f f6 74 b2 d3 0b cb a0 62 37 30 14 b7 78 6e 44 37 b1 77 ae c3 c8"
    ]

    let patchSigningKeys = [
        "04 B6 9D 17 34 F5 E4 25 BC C0 57 6A D1 F7 27 C1 31 1C 90 B6 EA 98 6F 00 6E 7E 9F 90 96 F6 A8 28 4F 12 BF 7D DF E1 54 A3 F1 D4 5A 0F 27 34 EC AB CA 6B 9E B5 6E E4 EC CA 87 85 3A D8 53 B6 A6 41 80",
        "04 A2 D8 47 89 90 94 5F 70 A9 57 0A DE 07 B1 55 BC 90 4D 2D 38 06 47 58 7B 12 39 17 01 30 9B D1 0B 59 90 C4 C4 7C 47 F1 F0 80 46 CB 6F 2D E0 74 8D 1F A7 F7 37 90 EC 9D 8D D6 37 21 27 78 52 88 38"
    ]


    /// whiteCryption Secure Key Box
    struct Libre3SKBCryptoLib {
        static let CRYPTO_RETURN_INVALID_COMMAND: Int = 0
        static let CRYPTO_RETURN_SUCCESS: Int = 1
        static let CRYPTO_RETURN_INVALID_PARAM: Int = -1
        static let CRYPTO_RETURN_LIB_ERROR: Int = -2
        static let CRYPTO_RETURN_LOW_MEMORY: Int = -3
        static let CRYPTO_RETURN_VERITY_FAILED: Int = -4

        static let CRYPTO_EXTENSION_INIT_LIB: Int = 1
        static let CRYPTO_EXTENSION_INIT_ECDH: Int = 2
        static let CRYPTO_EXTENSION_SET_PATCH_ATTRIB: Int = 3
        static let CRYPTO_EXTENSION_SET_CERTIFICATE: Int = 4
        static let CRYPTO_EXTENSION_GENERATE_EPHEMERAL: Int = 5
        static let CRYPTO_EXTENSION_GENERATE_KAUTH: Int = 6
        static let CRYPTO_EXTENSION_ENCRYPT: Int = 7
        static let CRYPTO_EXTENSION_DECRYPT: Int = 8
        static let CRYPTO_EXTENSION_EXPORT_KAUTH: Int = 9
        static let CRYPTO_EXTENSION_GENERATE_DB_KEY: Int = 10
        static let CRYPTO_EXTENSION_WRAP_DB_KEY: Int = 11
        static let CRYPTO_EXTENSION_UNWRAP_DB_KEY: Int = 12
        static let CRYPTO_EXTENSION_WRAP_DIAGNOSTIC_DATA: Int = 13

        let PUBLIC_KEY_TYPE_UNCOMPRESSED: UInt8 = 0x04
        let CRYPTO_PUBLIC_KEY_SIZE: Int = 64
        var patchSigningKey: Data
        var securityVersion: Int
        let max_key_index: Int = 2
        var app_private_key: Data
        var app_certificate: Data
    }


    // Frida-> crypto_lib.getAppCertificate()     => 162 bytes
    // Frida-> crypto_lib.generateEphemeralKeys() => 65 bytes


    class SecureFile {
        static let CRYPTO_EXTENSION_OPEN_LOG_CREATE = 10
        static let CRYPTO_EXTENSION_OPEN_LOG_APPEND = 11
        static let CRYPTO_EXTENSION_CLOSE_LOG = 12
        static let CRYPTO_EXTENSION_WRITE_LOG = 13
        static let CRYPTO_EXTENSION_LOG_SIZE = 15
        static let CRYPTO_EXTENSION_LOG_ERROR = 16
        static let LOG_FILE_NAME = "diagnostics.elog"

        // void latchSkb(String absolutePath):
        //   byte[] bytes = str.getBytes(C6581d.UTF_8);
        //   int process1 = Libre3SKBCryptoLib.process1(11, bytes, null);
        //
        // Frida-> var buffer = Java.array('byte', new Array(256).fill(0))
        // Frida-> p = crypto_lib.process1(11, Array.from("/data/data/com.freestylelibre3.app.it/files/diagnotics.elog", c => c.charCodeAt(0)), buffer)
    }

}

@Observable class Instinct: Libre3 {
}

@Observable class LibreSelect: Libre3 {
}

@Observable class Lingo: Libre3 {
}

// TODO: Libre Duo
@Observable class LibreX: Libre3 {

    // com.adc.dcm.gksensor.GlucoseKetoneSPL:
    //
    // ONE_MINUTE_PACKET_0_SIZE = 19
    // ONE_MINUTE_PACKET_1_SIZE = 18
    // ONE_MINUTE_PACKET_2_SIZE = 20
    // ONE_MINUTE_READING_RAW_SIZE = 57
    //
    // PATCH_ISF_RESPONSE_LEN = 51
    // PATCH_ISF_INDEX_HISTORIC_LIFECOUNT = 2
    // PATCH_ISF_INDEX_RATE_OF_CHANGE = 2
    // PATCH_ISF_INDEX_EXTENDED_CODE = 4
    // PATCH_ISF_INDEX_PROJECTED = 6
    // PATCH_ISF_INDEX_HISTORIC_CAPPED = 8
    // PATCH_ISF_INDEX_ACTIONABLE_TREND = 10
    // PATCH_ISF_INDEX_RESULT_UNCAPPED = 11
    // PATCH_ISF_INDEX_HISTORIC_UNCAPPED = 13
    // PATCH_ISF_INDEX_ANALYTE_TYPES = 34
    // PATCH_ISF_INDEX_TEMPERATURE = 37
    // PATCH_ISF_INDEX_CLINICAL_DATA = 37
    // PATCH_ISF_FIRST_ANALYTE_OFFSET = 4
    // PATCH_ISF_ANALYTE_LEN = 15
}
