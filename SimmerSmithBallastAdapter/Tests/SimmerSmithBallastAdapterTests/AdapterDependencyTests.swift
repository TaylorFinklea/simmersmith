import Testing
@testable import SimmerSmithBallastAdapter

@Test("adapter target resolves SimmerSmithKit and BallastCore")
func adapterDependenciesResolve() {
    #expect(BallastAdapterMarker.isAvailable)
}
