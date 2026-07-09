import Testing
import Foundation
@testable import LuxiconKit

@Suite struct PeopleJSONTests {
    private let people = [
        PersonImport(name: "Priya Patel", context: "Senior sysadmin; runs identity platform"),
        PersonImport(name: "Josh Nguyen"),
    ]

    @Test func exportParseRoundTrip() throws {
        let parsed = try PeopleJSON.parse(PeopleJSON.export(people))
        #expect(parsed == people)
    }

    @Test func templateRoundTripsAndInstructionsAreIgnored() throws {
        let parsed = try PeopleJSON.parse(PeopleJSON.template(existing: people))
        #expect(parsed == people)
    }

    @Test func acceptsBareArrayStringsAndUnknownFields() throws {
        let json = """
        [
          {"name": "Priya Patel", "context": "runs identity platform", "photo": "ignored.jpg"},
          "Josh Nguyen",
          {"name": "  ", "context": "dropped"}
        ]
        """
        let parsed = try PeopleJSON.parse(Data(json.utf8))
        #expect(parsed == [
            PersonImport(name: "Priya Patel", context: "runs identity platform"),
            PersonImport(name: "Josh Nguyen"),
        ])
    }

    @Test func envelopeWithoutPeopleThrows() {
        #expect(throws: PeopleJSON.ParseError.self) {
            try PeopleJSON.parse(Data(#"{"kind": "luxicon-people"}"#.utf8))
        }
    }

    @Test func emptyPeopleThrows() {
        #expect(throws: PeopleJSON.ParseError.self) {
            try PeopleJSON.parse(Data(#"{"people": []}"#.utf8))
        }
    }
}

@Suite struct PeopleAgentPromptTests {
    @Test func promptEmbedsCurrentPeopleAndSchema() {
        let prompt = PeopleJSON.agentPrompt(existing: [
            PersonImport(name: "Priya Patel", context: "identity platform"),
        ])
        #expect(prompt.contains("\"kind\": \"luxicon-people\""))
        #expect(prompt.contains("Priya Patel"))
        #expect(prompt.contains("Return only the finished JSON"))
    }

    @Test func promptHandlesEmptyRoster() {
        #expect(PeopleJSON.agentPrompt(existing: []).contains("(none yet)"))
    }

    @Test func promptAsksForDetailedContext() {
        let prompt = PeopleJSON.agentPrompt(existing: [])
        #expect(prompt.contains("2-3 paragraphs"))
        #expect(prompt.contains("recent project updates"))
    }
}
