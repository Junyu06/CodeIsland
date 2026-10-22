import Foundation
@testable import CodeIslandCore

/// A ``SubsessionContext`` without AppState: the cards a test sets up.
final class StubSubsessionContext: SubsessionContext {
    var cards: [String: SessionSnapshot]

    init(cards: [String: SessionSnapshot] = [:]) {
        self.cards = cards
    }
}

/// A card for the subsession tests.
func subsessionCard(
    source: String,
    status: AgentStatus = .processing,
    providerSessionId: String? = nil,
    transcriptPath: String? = nil,
    cliPid: pid_t? = nil,
    termBundleId: String? = nil,
    lastActivity: Date = Date(),
    startTime: Date = Date()
) -> SessionSnapshot {
    var card = SessionSnapshot(startTime: startTime)
    card.source = source
    card.status = status
    card.providerSessionId = providerSessionId
    card.transcriptPath = transcriptPath
    card.cliPid = cliPid
    card.termBundleId = termBundleId
    card.lastActivity = lastActivity
    return card
}
