import SwiftUI
import Testing
@testable import RoomForMac

@Suite("Motion")
struct MotionTests {
    @Test func hoverIsTheSpecSpring() {
        #expect(Motion.hover == .spring(response: 0.3, dampingFraction: 0.7))
        #expect(Motion.hoverScale == 1.02)
    }

    @Test func timings() {
        #expect(Motion.sectionCrossfade == .milliseconds(800))
        #expect(Motion.driftPeriod == .seconds(60))
        #expect(Motion.driftMaxScaleIncrease == 0.08)
        #expect(Motion.staggerStep == .milliseconds(30))
    }

    @Test func reduceMotionDropsTheAnimation() {
        #expect(Motion.animation(Motion.hover, reduceMotion: true) == nil)
        #expect(Motion.animation(.easeInOut(duration: 0.8), reduceMotion: true) == nil)
    }

    @Test func normalMotionKeepsTheAnimation() {
        #expect(Motion.animation(Motion.hover, reduceMotion: false) == Motion.hover)
        #expect(Motion.animation(.linear(duration: 1), reduceMotion: false) == .linear(duration: 1))
    }

    @Test(arguments: [
        (false, GlassTransitionKind.matchedGeometry),
        (true, GlassTransitionKind.materialize),
    ])
    func glassMorphsUnlessReduceMotion(reduceMotion: Bool, expected: GlassTransitionKind) {
        #expect(Motion.glassTransitionKind(reduceMotion: reduceMotion) == expected)
    }

    /// `GlassEffectTransition` is not Equatable, so this compares the reflected
    /// values. It fails loudly (first expectation) if a future SDK makes the
    /// two cases print alike, rather than passing without checking anything.
    @Test func glassTransitionReturnsTheKindsTransition() {
        let materialize = String(reflecting: GlassEffectTransition.materialize)
        let matchedGeometry = String(reflecting: GlassEffectTransition.matchedGeometry)
        #expect(materialize != matchedGeometry)
        #expect(String(reflecting: Motion.glassTransition(reduceMotion: true)) == materialize)
        #expect(String(reflecting: Motion.glassTransition(reduceMotion: false)) == matchedGeometry)
        #expect(String(reflecting: GlassTransitionKind.materialize.transition) == materialize)
        #expect(String(reflecting: GlassTransitionKind.matchedGeometry.transition) == matchedGeometry)
    }
}
