import Testing

/** End-to-end daemon tests land with Phase 2 (they boot a real devctld
    --foreground on a temp socket). The suite exists from day one so the target
    always builds. */
@Suite struct IntegrationPlaceholder {
    @Test func placeholder() {
        #expect(Bool(true))
    }
}
