import Testing

@testable import SimmerSmithKit

struct LegalDocumentURLsTests {
    @Test
    func privacyPolicyUsesTheGitHubPagesHost() {
        #expect(
            LegalDocumentURLs.privacy.absoluteString
                == "https://taylorfinklea.github.io/simmersmith/privacy/"
        )
    }

    @Test
    func termsUseTheGitHubPagesHost() {
        #expect(
            LegalDocumentURLs.terms.absoluteString
                == "https://taylorfinklea.github.io/simmersmith/terms/"
        )
    }
}
