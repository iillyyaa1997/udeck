import Foundation
import Testing
@testable import UDeckCore

/// The island's eight situations, the links that group them, and the rule that
/// decides what any one of them looks like.
///
/// The whole point of the design is that nothing changes until the operator
/// asks for it, so half of these tests are about a settings file that says
/// nothing and a panel that therefore looks exactly as it did.
@Suite("Island states")
struct IslandStatesTests {

    private var loud: PanelLook {
        PanelLook(glass: GlassAppearance(opacity: 1, tintStrength: 0.9), ink: .light, inkBrightness: 1)
    }

    private var quiet: PanelLook {
        PanelLook(glass: GlassAppearance(opacity: 0.3, tintStrength: 0.2), ink: .dark, inkBrightness: 0.4)
    }

    // MARK: - Eight of them, and no more

    @Test("there are eight situations: four phases in two surroundings")
    func eightStates() {
        #expect(IslandState.allCases.count == 8)
        #expect(Set(IslandState.allCases).count == 8)
        #expect(IslandState.allCases.contains(IslandState(phase: .collapsed, surrounding: .fullscreenApp)))
    }

    @Test("a state is written as one readable name")
    func stateNames() throws {
        #expect(IslandState(phase: .collapsed, surrounding: .ordinary).id == "collapsed.ordinary")
        #expect(IslandState(phase: .peek, surrounding: .fullscreenApp).id == "peek.fullscreen")
        #expect(IslandState(id: "open.fullscreen") == IslandState(phase: .open, surrounding: .fullscreenApp))
        #expect(IslandState(id: "open") == nil)
        #expect(IslandState(id: "sideways.ordinary") == nil)
    }

    // MARK: - Nothing changes until it is asked to

    @Test("out of the box every state is one link and the theme's own look")
    func defaultIsOneLink() {
        let states = IslandStates()
        #expect(states.links.count == 1)
        #expect(states.links[0].states.count == 8)
        for state in IslandState.allCases {
            #expect(states.look(for: state, isDark: false, base: loud) == loud)
            #expect(states.look(for: state, isDark: true, base: quiet) == quiet)
        }
    }

    @Test("a settings file written before states existed keeps its panel")
    func oldFileUnchanged() throws {
        let json = Data(#"{ "theme": { "manualIsDark": true, "dark": { "inkBrightness": 0.5 } } }"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
            .validated()
            .resolved(systemIsDark: false, hour: 12)
        for state in IslandState.allCases {
            #expect(settings.look(for: state) == settings.look)
        }
        #expect(settings.look.inkBrightness == 0.5)
    }

    // MARK: - A link with its own look

    @Test("a link's look reaches its own states and no others")
    func linkAppliesToItsStates() {
        let away = IslandLink(states: [
            IslandState(phase: .collapsed, surrounding: .ordinary),
            IslandState(phase: .collapsed, surrounding: .fullscreenApp),
        ])
        let rest = IslandLink(states: IslandState.allCases.filter { $0.phase != .collapsed })
        let states = IslandStates(links: [away, rest], light: [away.id: quiet])

        #expect(states.look(for: IslandState(phase: .collapsed), isDark: false, base: loud) == quiet)
        #expect(states.look(for: IslandState(phase: .collapsed, surrounding: .fullscreenApp),
                            isDark: false, base: loud) == quiet)
        #expect(states.look(for: IslandState(phase: .peek), isDark: false, base: loud) == loud)
        // The dark half was never given one, so it still says what the theme says.
        #expect(states.look(for: IslandState(phase: .collapsed), isDark: true, base: loud) == loud)
    }

    @Test("the two halves of the day hold their own numbers")
    func perThemeValues() {
        let link = IslandLink(states: [IslandState(phase: .collapsed)])
        let rest = IslandLink(states: IslandState.allCases.filter { $0.phase != .collapsed })
        let states = IslandStates(links: [link, rest], light: [link.id: quiet], dark: [link.id: loud])
        #expect(states.look(for: IslandState(phase: .collapsed), isDark: false, base: loud) == quiet)
        #expect(states.look(for: IslandState(phase: .collapsed), isDark: true, base: quiet) == loud)
    }

    // MARK: - Values kept the same everywhere

    @Test("a shared value comes from the theme, whatever the link says")
    func sharedBeatsTheLink() {
        let link = IslandLink(states: [IslandState(phase: .collapsed)])
        let rest = IslandLink(states: IslandState.allCases.filter { $0.phase != .collapsed })
        let states = IslandStates(links: [link, rest], shared: [.inkColour, .ink],
                                  light: [link.id: quiet])
        var base = loud
        base.inkColor = InkColor(red: 0.2, green: 0.9, blue: 0.4)

        let resolved = states.look(for: IslandState(phase: .collapsed), isDark: false, base: base)
        // Taken from the theme, because they are marked as the same everywhere…
        #expect(resolved.inkColor == base.inkColor)
        #expect(resolved.ink == base.ink)
        // …and everything else still belongs to the link.
        #expect(resolved.glass.opacity == quiet.glass.opacity)
        #expect(resolved.inkBrightness == quiet.inkBrightness)
    }

    // MARK: - A file edited by hand

    @Test("a state named twice belongs to the link that claimed it first")
    func duplicateStatesResolved() {
        let first = IslandLink(states: [IslandState(phase: .collapsed), IslandState(phase: .peek)])
        let second = IslandLink(states: [IslandState(phase: .collapsed), IslandState(phase: .open)])
        let states = IslandStates(links: [first, second]).validated()

        let collapsedLink = states.link(for: IslandState(phase: .collapsed))
        #expect(collapsedLink?.id == first.id)
        #expect(states.link(for: IslandState(phase: .open))?.id == second.id)
        // Every state still belongs somewhere, exactly once.
        let all = states.links.flatMap(\.states)
        #expect(all.count == 8)
        #expect(Set(all) == Set(IslandState.allCases))
    }

    @Test("a link left empty disappears rather than sitting there")
    func emptyLinksRemoved() {
        let empty = IslandLink(states: [])
        let states = IslandStates(links: [empty, IslandLink(states: IslandState.allCases)]).validated()
        #expect(!states.links.contains { $0.id == empty.id })
    }

    @Test("looks belonging to no link are dropped")
    func orphanLooksDropped() {
        let gone = UUID()
        let states = IslandStates(links: [IslandLink(states: IslandState.allCases)],
                                  light: [gone: quiet]).validated()
        #expect(states.light[gone] == nil)
    }

    @Test("a state uDeck no longer has costs that state, not the file")
    func unknownStateIsNotFatal() throws {
        let json = Data(#"{ "links": [ { "id": "5A2F4C4E-0000-0000-0000-000000000001", "states": ["collapsed.ordinary", "sideways.ordinary"] } ] }"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(IslandStates.self, from: json)
        }
    }

    @Test("what is written is what comes back")
    func roundTrips() throws {
        let link = IslandLink(states: [IslandState(phase: .collapsed)])
        let rest = IslandLink(states: IslandState.allCases.filter { $0.phase != .collapsed })
        let states = IslandStates(links: [link, rest], shared: [.inkColour], light: [link.id: quiet])
        let data = try JSONEncoder().encode(states)
        let back = try JSONDecoder().decode(IslandStates.self, from: data)
        #expect(back == states)
    }

    // MARK: - Which half of the day

    @Test("the resolved pole decides which numbers a state uses")
    func resolvedPoleIsUsed() {
        let link = IslandLink(states: [IslandState(phase: .collapsed)])
        let rest = IslandLink(states: IslandState.allCases.filter { $0.phase != .collapsed })
        var settings = AppSettings()
        settings.theme.source = .manual
        settings.theme.light = loud
        settings.theme.dark = loud
        settings.theme.states = IslandStates(links: [link, rest], light: [link.id: quiet], dark: [link.id: loud])

        settings.theme.manualIsDark = false
        let day = settings.resolved(systemIsDark: false, hour: 12)
        #expect(day.look(for: IslandState(phase: .collapsed)) == quiet)

        settings.theme.manualIsDark = true
        let night = settings.resolved(systemIsDark: false, hour: 12)
        #expect(night.look(for: IslandState(phase: .collapsed)) == loud)
    }

    // MARK: - Linking and unlinking

    @Test("linking takes the states out of their old links")
    func linkingMoves() {
        var states = IslandStates()
        let away = IslandState(phase: .collapsed, surrounding: .ordinary)
        let awayFull = IslandState(phase: .collapsed, surrounding: .fullscreenApp)
        states.link([away, awayFull], lightBase: loud, darkBase: loud)

        #expect(states.link(for: away)?.id == states.link(for: awayFull)?.id)
        #expect(states.link(for: away)?.states.count == 2)
        // Everything else is still together, and still accounted for.
        #expect(Set(states.links.flatMap(\.states)) == Set(IslandState.allCases))
        #expect(states.links.count == 2)
    }

    @Test("linking one state does nothing")
    func linkingOneIsNoOp() {
        var states = IslandStates()
        let before = states
        states.link([IslandState(phase: .open)], lightBase: loud, darkBase: loud)
        #expect(states == before)
    }

    @Test("a linked state carries the look it had, not the theme's")
    func linkingCarriesTheLook() {
        var states = IslandStates()
        let away = IslandState(phase: .collapsed)
        let peek = IslandState(phase: .peek)
        // Give the away state a look of its own first.
        states.unlink([away], lightBase: loud, darkBase: loud)
        let awayLink = states.link(for: away)!
        states.light[awayLink.id] = quiet

        states.link([away, peek], lightBase: loud, darkBase: loud)
        // Both now look like what the away state looked like.
        #expect(states.look(for: away, isDark: false, base: loud) == quiet)
        #expect(states.look(for: peek, isDark: false, base: loud) == quiet)
    }

    @Test("unlinking keeps what the state looked like a moment ago")
    func unlinkingKeepsTheLook() {
        var states = IslandStates()
        let away = IslandState(phase: .collapsed)
        let peek = IslandState(phase: .peek)
        states.link([away, peek], lightBase: loud, darkBase: loud)
        states.light[states.link(for: away)!.id] = quiet

        states.unlink([peek], lightBase: loud, darkBase: loud)
        #expect(states.link(for: peek)?.states == [peek])
        #expect(states.look(for: peek, isDark: false, base: loud) == quiet)
        // And the one left behind is unchanged.
        #expect(states.look(for: away, isDark: false, base: loud) == quiet)
    }

    @Test("unlinking a state that is already alone does nothing")
    func unlinkingAloneIsNoOp() {
        var states = IslandStates()
        states.unlink([IslandState(phase: .open)], lightBase: loud, darkBase: loud)
        let before = states
        states.unlink([IslandState(phase: .open)], lightBase: loud, darkBase: loud)
        #expect(states == before)
    }

    @Test("every state still belongs somewhere after any of this")
    func partitionHolds() {
        var states = IslandStates()
        states.link([IslandState(phase: .collapsed), IslandState(phase: .peek)], lightBase: loud, darkBase: loud)
        states.unlink([IslandState(phase: .peek)], lightBase: loud, darkBase: loud)
        states.link([IslandState(phase: .peek), IslandState(phase: .open),
                     IslandState(phase: .open, surrounding: .fullscreenApp)], lightBase: loud, darkBase: loud)

        let all = states.links.flatMap(\.states)
        #expect(all.count == 8)
        #expect(Set(all) == Set(IslandState.allCases))
    }
}
