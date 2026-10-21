import Testing
@testable import PhpSwitcherCore

@Suite struct PhpConstraintTests {
    func v(_ s: String) -> VersionNumber { VersionNumber.parse(s)! }

    @Test func caret() {
        let c = PhpConstraint("^8.2")!
        #expect(c.satisfies(v("8.2.0")))
        #expect(c.satisfies(v("8.4.12")))
        #expect(!c.satisfies(v("8.1.30")))
        #expect(!c.satisfies(v("9.0.0")))
    }

    @Test func tilde() {
        #expect(PhpConstraint("~8.1")!.satisfies(v("8.3.1")))
        #expect(!PhpConstraint("~8.1.3")!.satisfies(v("8.2.0")))
        #expect(PhpConstraint("~8.1.3")!.satisfies(v("8.1.9")))
    }

    @Test func rangesAndAlternatives() {
        let c = PhpConstraint(">=8.1 <8.4")!
        #expect(c.satisfies(v("8.3.9")))
        #expect(!c.satisfies(v("8.4.0")))
        let or = PhpConstraint("^7.4 || ^8.0")!
        #expect(or.satisfies(v("7.4.33")))
        #expect(or.satisfies(v("8.5.0")))
        #expect(!or.satisfies(v("7.3.0")))
        #expect(PhpConstraint(">= 8.1, < 8.3")!.satisfies(v("8.2.1")))
        #expect(PhpConstraint("8.1 - 8.3")!.satisfies(v("8.3.20")))
        #expect(!PhpConstraint("8.1 - 8.3")!.satisfies(v("8.4.0")))
    }

    @Test func wildcardsAndBare() {
        #expect(PhpConstraint("8.2.*")!.satisfies(v("8.2.30")))
        #expect(!PhpConstraint("8.2.*")!.satisfies(v("8.3.0")))
        #expect(PhpConstraint("8.2")!.satisfies(v("8.2.11")))
        #expect(PhpConstraint("*")!.satisfies(v("5.6.0")))
        #expect(PhpConstraint("^8.2@dev")!.satisfies(v("8.3.0")))
    }

    @Test func versionWithoutPatchMatchesItsMinor() {
        // The toolbar knows "8.3" only sometimes; ^8.3.5 should still count.
        #expect(PhpConstraint("^8.3.5")!.satisfies(VersionNumber(major: 8, minor: 3)))
    }

    @Test func garbageIsNil() {
        #expect(PhpConstraint("") == nil)
        #expect(PhpConstraint("latest") == nil)
    }

    @Test func bestMatchPicksNewestCompatible() {
        let installed = ["8.1.31", "8.2.28", "8.3.21", "8.4.11"].map {
            PhpInstallation(formula: "php@" + v($0).short, version: v($0))
        }
        #expect(PhpConstraint(">=8.1 <8.4")!.bestMatch(in: installed)?.version.short == "8.3")
        #expect(PhpConstraint("^9.0")!.bestMatch(in: installed) == nil)
    }
}
