import Testing
import Foundation
import ApplicationServices
@testable import trapps

struct MenuBarScannerTests {
    let scanner = MenuBarScanner()

    // A stand-in entry; disambiguated() only reads/rewrites `title`, so the
    // AXUIElement is never dereferenced here.
    private func entry(_ title: String) -> MenuBarEntry {
        MenuBarEntry(
            element: AXUIElementCreateApplication(0),
            pid: 0,
            appName: "App",
            icon: nil,
            title: title,
            frame: .zero,
            isHidden: false
        )
    }

    @Test func uniqueTitlesAreUnchanged() {
        let titles = scanner.disambiguated([entry("A"), entry("B"), entry("C")]).map(\.title)
        #expect(titles == ["A", "B", "C"])
    }

    @Test func duplicatesGetNumberedSuffixesLeavingFirstBare() {
        let titles = scanner.disambiguated([entry("A"), entry("A"), entry("A")]).map(\.title)
        #expect(titles == ["A", "A (2)", "A (3)"])
    }

    @Test func disambiguationIsPerTitle() {
        let titles = scanner.disambiguated([entry("A"), entry("B"), entry("A")]).map(\.title)
        #expect(titles == ["A", "B", "A (2)"])
    }

    @Test func emptyInputYieldsEmptyOutput() {
        #expect(scanner.disambiguated([]).isEmpty)
    }
}
