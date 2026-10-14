import Foundation
@testable import DokkitKit

struct Phone: Decodable {
    var name: String
    var slot: String
    var token: String
    var phoneKey: String
    var pairing: Pairing
    var pairingCode: String
    var slotAnswer: SlotAnswer
    enum CodingKeys: String, CodingKey {
        case name, slot, token, phoneKey = "phone_key", pairing, pairingCode = "pairing_code", slotAnswer = "slot_answer"
    }
}

struct Sealing_: Decodable {
    var uploadKey: String
    var mailbox: String
    var counter: Int
    var snapshotJson: String
    var phones: [Phone]
    enum CodingKeys: String, CodingKey {
        case uploadKey = "upload_key", mailbox, counter, snapshotJson = "snapshot_json", phones
    }
}

enum Fixtures {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static let sealing = try! JSONDecoder().decode(Sealing_.self, from: data("sealing"))
    static let snapshotData = data("snapshot")
    static let snapshot = try! Snapshot.decode(snapshotData)
    static var raw: [String: Any] { try! JSONSerialization.jsonObject(with: snapshotData) as! [String: Any] }
    static let now = Snapshot.parseDate("2026-10-14T00:00:00Z")!
}
