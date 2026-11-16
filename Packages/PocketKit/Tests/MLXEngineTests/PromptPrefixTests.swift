import Testing
@testable import MLXEngine

/// The kept prefix logic that runs without a model or the GPU.
struct PromptPrefixTests {
    @Test func keepsACopyOnlyUpToTheCap() {
        let cap = 256 << 20
        #expect(PromptPrefix.shouldKeep(cacheBytes: 0, limit: cap))
        #expect(PromptPrefix.shouldKeep(cacheBytes: cap, limit: cap))
        #expect(!PromptPrefix.shouldKeep(cacheBytes: cap + 1, limit: cap))
    }

    @Test func commonPrefixLength() {
        #expect(PromptPrefix.commonPrefixLength([1, 2, 3, 4], [1, 2, 9]) == 2)
        #expect(PromptPrefix.commonPrefixLength([], [1]) == 0)
        #expect(PromptPrefix.commonPrefixLength([5, 6], [5, 6, 7]) == 2)
    }
}
