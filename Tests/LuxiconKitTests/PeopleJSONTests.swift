import Testing
import Foundation
@testable import LuxiconKit

@Suite struct PeopleJSONTests {
    private let people = [
        PersonImport(name: "Priya Patel", context: "Senior sysadmin; runs identity platform"),
        PersonImport(name: "Josh Nguyen"),
    ]
    private let me = PersonImport(name: "Alex Kim", context: "Director of infrastructure")

    @Test func exportParseRoundTrip() throws {
        let parsed = try PeopleJSON.parse(PeopleJSON.export(people))
        #expect(parsed == PeopleFile(people: people))
    }

    @Test func meRoundTrips() throws {
        let parsed = try PeopleJSON.parse(PeopleJSON.export(people, me: me))
        #expect(parsed == PeopleFile(myContext: me.context, people: people))
    }

    @Test func templateRoundTripsAndInstructionsAreIgnored() throws {
        let parsed = try PeopleJSON.parse(PeopleJSON.template(existing: people, me: me))
        #expect(parsed == PeopleFile(myContext: me.context, people: people))
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
        #expect(parsed == PeopleFile(people: [
            PersonImport(name: "Priya Patel", context: "runs identity platform"),
            PersonImport(name: "Josh Nguyen"),
        ]))
    }

    @Test func acceptsMeAsObjectOrBareString() throws {
        let object = try PeopleJSON.parse(
            Data(#"{"me": {"name": "Alex", "context": "about me"}, "people": ["Priya"]}"#.utf8))
        #expect(object.myContext == "about me")

        let bare = try PeopleJSON.parse(Data(#"{"me": "about me", "people": ["Priya"]}"#.utf8))
        #expect(bare.myContext == "about me")
    }

    @Test func meOnlyFileParses() throws {
        let parsed = try PeopleJSON.parse(Data(#"{"me": {"context": "about me"}, "people": []}"#.utf8))
        #expect(parsed == PeopleFile(myContext: "about me", people: []))
    }

    @Test func meWithoutContextIsIgnored() throws {
        let parsed = try PeopleJSON.parse(Data(#"{"me": {"name": "Alex"}, "people": ["Priya"]}"#.utf8))
        #expect(parsed.myContext == nil)
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
        let prompt = PeopleJSON.agentPrompt(
            existing: [PersonImport(name: "Priya Patel", context: "identity platform")],
            me: PersonImport(name: "Alex Kim", context: "infrastructure director"))
        #expect(prompt.contains("\"kind\": \"luxicon-people\""))
        #expect(prompt.contains("Priya Patel"))
        #expect(prompt.contains("Alex Kim"))
        #expect(prompt.contains("Return only the finished JSON"))
    }

    @Test func promptHandlesEmptyRoster() {
        #expect(PeopleJSON.agentPrompt(existing: []).contains("(none yet)"))
    }

    @Test func promptExplainsMeEntry() {
        let prompt = PeopleJSON.agentPrompt(existing: [])
        #expect(prompt.contains("\"me\""))
        #expect(prompt.contains("about-me context"))
    }

    @Test func promptAsksForDetailedContext() {
        let prompt = PeopleJSON.agentPrompt(existing: [])
        #expect(prompt.contains("2-3 paragraphs"))
        #expect(prompt.contains("recent project updates"))
    }
}
