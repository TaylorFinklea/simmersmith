import Foundation
import Testing
@testable import SimmerSmithKit

// SP-C AI-2 Task 1 — Headless tests for the on-device deterministic import core:
//   • RecipeURLFetcher host guard (https-only + private-range rejection) + body cap.
//   • JSONLDRecipeExtractor against flat / @graph-nested / HowToStep fixtures, and
//     the no-JSON-LD → nil case.

// MARK: - Test transport

/// A canned RecipeHTTPTransport: returns a fixed body + status with no real network.
private struct StubTransport: RecipeHTTPTransport {
    let body: Data
    let status: Int
    init(body: String, status: Int = 200) {
        self.body = Data(body.utf8)
        self.status = status
    }
    init(bytes: Int, status: Int = 200) {
        self.body = Data(repeating: 0x41, count: bytes)
        self.status = status
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

// MARK: - RecipeURLFetcher host guard

@Suite("RecipeURLFetcher host guard")
struct RecipeURLFetcherGuardTests {

    @Test("rejects non-https schemes")
    func rejectsInsecureScheme() {
        #expect(throws: RecipeURLFetchError.self) {
            try RecipeURLFetcher.validatedURL("http://example.com/recipe")
        }
    }

    @Test("rejects localhost / loopback / .local")
    func rejectsLocalHosts() {
        #expect(RecipeURLFetcher.isPrivateHost("localhost"))
        #expect(RecipeURLFetcher.isPrivateHost("foo.localhost"))
        #expect(RecipeURLFetcher.isPrivateHost("printer.local"))
        #expect(RecipeURLFetcher.isPrivateHost("127.0.0.1"))
        #expect(RecipeURLFetcher.isPrivateHost("0.0.0.0"))
        #expect(RecipeURLFetcher.isPrivateHost("::1"))
    }

    @Test("rejects RFC-1918 private ranges")
    func rejectsPrivateIPv4() {
        #expect(RecipeURLFetcher.isPrivateHost("10.0.0.5"))
        #expect(RecipeURLFetcher.isPrivateHost("10.255.255.255"))
        #expect(RecipeURLFetcher.isPrivateHost("172.16.0.1"))
        #expect(RecipeURLFetcher.isPrivateHost("172.31.255.255"))
        #expect(RecipeURLFetcher.isPrivateHost("192.168.1.1"))
        // 172.15 and 172.32 are NOT private.
        #expect(!RecipeURLFetcher.isPrivateHost("172.15.0.1"))
        #expect(!RecipeURLFetcher.isPrivateHost("172.32.0.1"))
    }

    @Test("rejects link-local 169.254/16 and IPv6 fe80::/fc00::")
    func rejectsLinkLocal() {
        #expect(RecipeURLFetcher.isPrivateHost("169.254.1.1"))
        #expect(RecipeURLFetcher.isPrivateHost("fe80::1"))
        #expect(RecipeURLFetcher.isPrivateHost("fd00::1"))
        #expect(RecipeURLFetcher.isPrivateHost("fc00::1"))
    }

    // SP-C AI-2 review C2a — CGNAT 100.64.0.0/10 (RFC 6598). The server blocks it
    // (parser.py `_CGNAT_NETWORK`) because some networks route shared-NAT space to
    // internal infrastructure, so it's a live SSRF target the RFC-1918 checks miss.
    @Test("rejects CGNAT 100.64.0.0/10")
    func rejectsCGNAT() {
        #expect(RecipeURLFetcher.isPrivateHost("100.64.0.1"))
        #expect(RecipeURLFetcher.isPrivateHost("100.100.50.50"))
        #expect(RecipeURLFetcher.isPrivateHost("100.127.255.255"))
        // Just outside the /10 — 100.63 and 100.128 are PUBLIC.
        #expect(!RecipeURLFetcher.isPrivateHost("100.63.255.255"))
        #expect(!RecipeURLFetcher.isPrivateHost("100.128.0.1"))
    }

    @Test("accepts https public hosts")
    func acceptsPublicHTTPS() throws {
        let url = try RecipeURLFetcher.validatedURL("https://www.seriouseats.com/recipe")
        #expect(url.host == "www.seriouseats.com")
        #expect(!RecipeURLFetcher.isPrivateHost("seriouseats.com"))
        #expect(!RecipeURLFetcher.isPrivateHost("8.8.8.8"))
        #expect(RecipeURLFetcher.isPrivateHost("172.20.10.1")) // 172.20 IS private
    }

    @Test("validatedURL throws on bare/no-host strings")
    func rejectsInvalidURL() {
        #expect(throws: RecipeURLFetchError.self) {
            try RecipeURLFetcher.validatedURL("not a url")
        }
        #expect(throws: RecipeURLFetchError.self) {
            try RecipeURLFetcher.validatedURL("https://")
        }
    }

    // SP-C AI-2 review C1 — redirect re-validation. The production transport's
    // URLSession delegate decides whether to follow each redirect hop by calling
    // `validatedURL(newRequest.url)` and CANCELLING when it throws. This test exercises
    // that decision directly: a public→private redirect target is rejected (delegate
    // hands URLSession `nil`), a public→public one is accepted. The CGNAT hop is also
    // rejected, confirming C2's guard applies to redirect targets too.
    @Test("redirect-hop validation: private/CGNAT targets rejected, public accepted")
    func redirectHopDecision() throws {
        // A 30x to a private host must be rejected on the hop.
        #expect(throws: RecipeURLFetchError.self) {
            try RecipeURLFetcher.validatedURL("https://169.254.169.254/latest/meta-data/")
        }
        #expect(throws: RecipeURLFetchError.self) {
            try RecipeURLFetcher.validatedURL("https://10.0.0.5/internal")
        }
        #expect(throws: RecipeURLFetchError.self) {
            try RecipeURLFetcher.validatedURL("https://100.64.0.1/internal")
        }
        // A redirect to another public https host is allowed to proceed.
        let ok = try RecipeURLFetcher.validatedURL("https://www.allrecipes.com/recipe/2")
        #expect(ok.host == "www.allrecipes.com")
    }
}

// MARK: - RecipeURLFetcher fetch + body cap

@Suite("RecipeURLFetcher fetch")
struct RecipeURLFetcherFetchTests {

    @Test("fetches HTML for a valid https host")
    func fetchesHTML() async throws {
        let fetcher = RecipeURLFetcher(transport: StubTransport(body: "<html>hi</html>"))
        let html = try await fetcher.fetchHTML(from: "https://example.com/recipe")
        #expect(html == "<html>hi</html>")
    }

    @Test("rejects a private host before fetching")
    func guardRunsBeforeFetch() async {
        let fetcher = RecipeURLFetcher(transport: StubTransport(body: "<html>secret</html>"))
        await #expect(throws: RecipeURLFetchError.self) {
            try await fetcher.fetchHTML(from: "https://192.168.0.1/admin")
        }
    }

    @Test("caps oversize bodies")
    func capsBody() async {
        let fetcher = RecipeURLFetcher(
            transport: StubTransport(bytes: 50),
            maxBytes: 10
        )
        await #expect(throws: RecipeURLFetchError.self) {
            try await fetcher.fetchHTML(from: "https://example.com/big")
        }
    }

    @Test("surfaces non-200 status")
    func surfacesHTTPError() async {
        let fetcher = RecipeURLFetcher(transport: StubTransport(body: "nope", status: 404))
        await #expect(throws: RecipeURLFetchError.self) {
            try await fetcher.fetchHTML(from: "https://example.com/missing")
        }
    }
}

// MARK: - JSONLDRecipeExtractor

@Suite("JSONLDRecipeExtractor")
struct JSONLDRecipeExtractorTests {

    // Fixture 1 — a flat Recipe node, string instructions, string ingredients.
    static let flatRecipeHTML = """
    <html><head>
    <script type="application/ld+json">
    {
      "@context": "https://schema.org",
      "@type": "Recipe",
      "name": "Simple Pancakes",
      "recipeCuisine": "American",
      "recipeYield": "4 servings",
      "prepTime": "PT10M",
      "cookTime": "PT15M",
      "keywords": "breakfast, easy, pancakes",
      "recipeIngredient": [
        "2 cups flour",
        "1 tbsp sugar",
        "2 cups flour"
      ],
      "recipeInstructions": "Mix everything. Cook on a griddle."
    }
    </script>
    </head><body>...</body></html>
    """

    // Fixture 2 — @graph with the Recipe nested among other node types; instructions
    // as an array of HowToStep objects; recipeYield as a bare number.
    static let graphRecipeHTML = """
    <html><head>
    <script type="application/ld+json">
    {
      "@context": "https://schema.org",
      "@graph": [
        { "@type": "WebSite", "name": "Cooking Blog" },
        { "@type": "Organization", "name": "Acme" },
        {
          "@type": ["Recipe", "NewsArticle"],
          "name": "Roast Chicken &amp; Potatoes",
          "recipeYield": 6,
          "prepTime": "PT20M",
          "cookTime": "PT1H30M",
          "recipeCuisine": ["French"],
          "recipeIngredient": ["1 whole chicken", "4 potatoes"],
          "recipeInstructions": [
            { "@type": "HowToStep", "text": "Preheat the oven to 425F." },
            { "@type": "HowToStep", "text": "Season the chicken." },
            { "@type": "HowToStep", "name": "Roast", "text": "Roast for 90 minutes." }
          ]
        }
      ]
    }
    </script>
    </head><body></body></html>
    """

    // Fixture 3 — instructions as a HowToSection wrapping HowToSteps (itemListElement).
    static let sectionRecipeHTML = """
    <html><head>
    <script type="application/ld+json">
    {
      "@type": "Recipe",
      "name": "Layered Dip",
      "recipeIngredient": ["1 can beans", "1 cup cheese"],
      "recipeInstructions": [
        {
          "@type": "HowToSection",
          "name": "Assemble",
          "itemListElement": [
            { "@type": "HowToStep", "text": "Spread the beans." },
            { "@type": "HowToStep", "text": "Top with cheese." }
          ]
        }
      ]
    }
    </script>
    </head><body></body></html>
    """

    // Fixture 4 — page with JSON-LD but no Recipe node.
    static let noRecipeHTML = """
    <html><head>
    <script type="application/ld+json">
    { "@context": "https://schema.org", "@type": "WebPage", "name": "About Us" }
    </script>
    </head><body></body></html>
    """

    @Test("flat Recipe → correct draft")
    func flatRecipe() throws {
        let draft = try #require(JSONLDRecipeExtractor.extract(
            fromHTML: Self.flatRecipeHTML,
            sourceURL: "https://example.com/pancakes"
        ))
        #expect(draft.name == "Simple Pancakes")
        #expect(draft.cuisine == "American")
        #expect(draft.servings == 4)
        #expect(draft.prepMinutes == 10)
        #expect(draft.cookMinutes == 15)
        #expect(draft.tags == ["breakfast", "easy", "pancakes"])
        // Duplicate "2 cups flour" deduped.
        #expect(draft.ingredients.map(\.ingredientName) == ["2 cups flour", "1 tbsp sugar"])
        #expect(draft.steps.count == 1)
        #expect(draft.steps.first?.instruction == "Mix everything. Cook on a griddle.")
        #expect(draft.source == "url_import")
        #expect(draft.sourceUrl == "https://example.com/pancakes")
    }

    @Test("@graph-nested Recipe with HowToStep instructions")
    func graphRecipe() throws {
        let draft = try #require(JSONLDRecipeExtractor.extract(
            fromHTML: Self.graphRecipeHTML,
            sourceURL: "https://blog.example.com/roast"
        ))
        #expect(draft.name == "Roast Chicken & Potatoes") // entity decoded
        #expect(draft.cuisine == "French")
        #expect(draft.servings == 6)
        #expect(draft.prepMinutes == 20)
        #expect(draft.cookMinutes == 90) // PT1H30M
        #expect(draft.ingredients.map(\.ingredientName) == ["1 whole chicken", "4 potatoes"])
        #expect(draft.steps.map(\.instruction) == [
            "Preheat the oven to 425F.",
            "Season the chicken.",
            "Roast for 90 minutes.",
        ])
        // Steps are sequentially ordered.
        #expect(draft.steps.map(\.sortOrder) == [1, 2, 3])
    }

    @Test("HowToSection instructions flatten with substeps")
    func sectionRecipe() throws {
        let draft = try #require(JSONLDRecipeExtractor.extract(
            fromHTML: Self.sectionRecipeHTML
        ))
        #expect(draft.name == "Layered Dip")
        #expect(draft.steps.count == 1)
        let section = try #require(draft.steps.first)
        #expect(section.instruction == "Assemble")
        #expect(section.substeps.map(\.instruction) == ["Spread the beans.", "Top with cheese."])
    }

    @Test("no Recipe JSON-LD → nil")
    func noRecipe() {
        #expect(JSONLDRecipeExtractor.extract(fromHTML: Self.noRecipeHTML) == nil)
        #expect(JSONLDRecipeExtractor.extract(fromHTML: "<html><body>plain</body></html>") == nil)
    }

    @Test("ISO-8601 duration parsing")
    func durationParsing() {
        #expect(JSONLDRecipeExtractor.parseDurationMinutes("PT15M") == 15)
        #expect(JSONLDRecipeExtractor.parseDurationMinutes("PT1H") == 60)
        #expect(JSONLDRecipeExtractor.parseDurationMinutes("PT1H30M") == 90)
        #expect(JSONLDRecipeExtractor.parseDurationMinutes("P0D") == nil)
        #expect(JSONLDRecipeExtractor.parseDurationMinutes("nonsense") == nil)
        #expect(JSONLDRecipeExtractor.parseDurationMinutes(nil) == nil)
    }

    @Test("recipeYield parsing (string, number, array)")
    func yieldParsing() {
        #expect(JSONLDRecipeExtractor.parseServings("4 servings") == 4)
        #expect(JSONLDRecipeExtractor.parseServings(6) == 6)
        #expect(JSONLDRecipeExtractor.parseServings(["", "8 portions"]) == 8)
        #expect(JSONLDRecipeExtractor.parseServings("") == nil)
    }
}
