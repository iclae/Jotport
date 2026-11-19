public struct BridgeEvent: Codable {
    public var schemaVersion: Int
    public var eventID: String
    public var runID: String
    public var sessionID: String
    public var turnID: Int
    public var sequence: Int
    public var source: String
    public var type: String
    public var time: String
    public var text: String?

    public init(schemaVersion: Int, eventID: String, runID: String, sessionID: String, turnID: Int,
                sequence: Int, source: String, type: String, time: String, text: String? = nil) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.runID = runID
        self.sessionID = sessionID
        self.turnID = turnID
        self.sequence = sequence
        self.source = source
        self.type = type
        self.time = time
        self.text = text
    }
}
