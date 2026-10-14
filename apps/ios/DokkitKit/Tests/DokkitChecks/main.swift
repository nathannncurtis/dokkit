import Foundation


await run("RelayTests.fetchesAndSendsBearerAndEtag") { try await RelayTests().fetchesAndSendsBearerAndEtag() }
await run("RelayTests.notModified") { try await RelayTests().notModified() }
await run("RelayTests.notFound") { try await RelayTests().notFound() }
await run("RelayTests.rateLimited") { try await RelayTests().rateLimited() }
await run("RelayTests.otherStatusAndBadBody") { try await RelayTests().otherStatusAndBadBody() }
await run("RelayTests.refusesPlainHTTP") { try await RelayTests().refusesPlainHTTP() }
await run("RelayTests.refresherOpensKeepsAndRefusesReplay") { try await RelayTests().refresherOpensKeepsAndRefusesReplay() }
await run("RelayTests.refresherTreatsBrokenBodyAsNoSnapshot") { try await RelayTests().refresherTreatsBrokenBodyAsNoSnapshot() }
await run("StoreTests.addReplaceRemove") { try await StoreTests().addReplaceRemove() }
await run("StoreTests.diskFiles") { try await StoreTests().diskFiles() }
await run("SealingTests.opensEveryPhonesAnswer") { try await SealingTests().opensEveryPhonesAnswer() }
await run("SealingTests.parsesEveryPairingCode") { try await SealingTests().parsesEveryPairingCode() }
await run("SealingTests.refusesBadPairingCodes") { try await SealingTests().refusesBadPairingCodes() }
await run("SealingTests.checksum") { try await SealingTests().checksum() }
await run("SealingTests.wrongCounterInAdditionalDataFails") { try await SealingTests().wrongCounterInAdditionalDataFails() }
await run("SealingTests.wrongSlotFails") { try await SealingTests().wrongSlotFails() }
await run("SealingTests.anotherPhonesKeyFails") { try await SealingTests().anotherPhonesKeyFails() }
await run("SealingTests.anyChangedByteFails") { try await SealingTests().anyChangedByteFails() }
await run("SealingTests.counterRule") { try await SealingTests().counterRule() }
await run("SealingTests.gzipRejectsGarbage") { try await SealingTests().gzipRejectsGarbage() }
await run("SnapshotTests.decodesWithoutLoss") { try await SnapshotTests().decodesWithoutLoss() }
await run("SnapshotTests.toleratesUnknownFieldsAndValues") { try await SnapshotTests().toleratesUnknownFieldsAndValues() }
await run("SnapshotTests.needsYouScreen") { try await SnapshotTests().needsYouScreen() }
await run("SnapshotTests.everythingScreen") { try await SnapshotTests().everythingScreen() }
await run("SnapshotTests.serviceScreen") { try await SnapshotTests().serviceScreen() }
await run("SnapshotTests.vitalsAreShown") { try await SnapshotTests().vitalsAreShown() }
await run("SnapshotTests.ageTextAndWarning") { try await SnapshotTests().ageTextAndWarning() }

print("\(assertions) assertions, \(failures) failed")
exit(failures == 0 ? 0 : 1)
