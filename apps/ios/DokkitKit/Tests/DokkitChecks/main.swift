import Foundation


await run("RelayTests.fetchesAndSendsBearerAndEtag") { try await RelayTests().fetchesAndSendsBearerAndEtag() }
await run("RelayTests.notModified") { try await RelayTests().notModified() }
await run("RelayTests.notFound") { try await RelayTests().notFound() }
await run("RelayTests.rateLimited") { try await RelayTests().rateLimited() }
await run("RelayTests.otherStatusAndBadBody") { try await RelayTests().otherStatusAndBadBody() }
await run("RelayTests.refusesRedirect") { try await RelayTests().refusesRedirect() }
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
await run("SnapshotTests.serviceScreen") { try await SnapshotTests().serviceScreen() }
await run("SnapshotTests.chartDrawsFromValues") { try await SnapshotTests().chartDrawsFromValues() }
await run("SnapshotTests.realChartsDecode") { try await SnapshotTests().realChartsDecode() }
await run("SnapshotTests.ageTextAndWarning") { try await SnapshotTests().ageTextAndWarning() }
await run("HomeTests.fixtureHome") { try await HomeTests().fixtureHome() }
await run("HomeTests.fineBox") { try await HomeTests().fineBox() }
await run("HomeTests.attentionBox") { try await HomeTests().attentionBox() }
await run("HomeTests.meters") { try await HomeTests().meters() }
await run("HomeTests.openedList") { try await HomeTests().openedList() }
await run("HomeTests.groupsAndKinds") { try await HomeTests().groupsAndKinds() }
await run("HomeTests.countLines") { try await HomeTests().countLines() }
await run("HomeTests.hiddenThings") { try await HomeTests().hiddenThings() }
await run("HomeTests.sorting") { try await HomeTests().sorting() }
await run("HomeTests.downtimeAndStatus") { try await HomeTests().downtimeAndStatus() }

print("\(assertions) assertions, \(failures) failed")
exit(failures == 0 ? 0 : 1)
