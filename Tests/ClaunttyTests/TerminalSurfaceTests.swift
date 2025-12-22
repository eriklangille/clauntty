import XCTest
@testable import Clauntty

@MainActor
final class TerminalSurfaceTests: XCTestCase {

    func testTerminalSurfaceViewCreationWithoutApp() {
        // TerminalSurfaceView should handle nil app gracefully
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        // View should exist but surface should be nil
        XCTAssertNotNil(view)
        XCTAssertNil(view.surface, "Surface should be nil when no app provided")
    }

    func testGhosttyAppCreation() {
        // Test that GhosttyApp initializes correctly
        // Surface creation is tested via visual tests (requires Metal)
        GhosttyGlobal.initialize()

        let ghosttyApp = GhosttyApp()
        XCTAssertEqual(ghosttyApp.readiness, .ready, "GhosttyApp should be ready")
        XCTAssertNotNil(ghosttyApp.app, "ghostty_app_t should be created")

        // Note: Creating TerminalSurfaceView with app throws in headless environment
        // because ghostty_surface_new tries to set up Metal layers.
        // Visual tests in simulator validate actual surface creation.
    }

    func testTerminalSurfaceViewIsMetalBacked() {
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        // Verify it uses CAMetalLayer
        XCTAssertTrue(view.layer is CAMetalLayer, "View should use CAMetalLayer for rendering")
    }

    func testTerminalSurfaceViewCanBecomeFirstResponder() {
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        XCTAssertTrue(view.canBecomeFirstResponder, "TerminalSurfaceView should be able to become first responder for keyboard input")
    }

    func testTerminalSurfaceViewHasText() {
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        // UIKeyInput requires hasText - we always return true
        XCTAssertTrue(view.hasText)
    }

    func testTerminalSurfaceViewSizeChange() {
        // Test size change with nil surface (safe path)
        // Full surface testing requires simulator with Metal - see visual tests
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        // Should not crash when size changes even without surface
        view.sizeDidChange(CGSize(width: 800, height: 600))
        view.sizeDidChange(CGSize(width: 320, height: 480))

        // View should exist, surface is nil (expected in unit tests)
        XCTAssertNotNil(view)
    }

    // MARK: - SSH Data Flow Tests

    func testOnTextInputCallback() {
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        var receivedData: Data?
        view.onTextInput = { data in
            receivedData = data
        }

        // Simulate text input
        view.insertText("hello")

        XCTAssertEqual(receivedData, "hello".data(using: .utf8))
    }

    func testBackspaceGeneratesCorrectData() {
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        var receivedData: Data?
        view.onTextInput = { data in
            receivedData = data
        }

        // Simulate backspace
        view.deleteBackward()

        // Should generate DEL (0x7F)
        XCTAssertEqual(receivedData, Data([0x7F]))
    }

    func testWriteSSHOutputWithNoSurface() {
        // Test that writeSSHOutput handles nil surface gracefully
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        // Should not crash when writing with no surface
        view.writeSSHOutput(Data("test data".utf8))

        // View should still exist
        XCTAssertNotNil(view)
        XCTAssertNil(view.surface)
    }

    func testMultipleKeyInputs() {
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        var allReceivedData = Data()
        view.onTextInput = { data in
            allReceivedData.append(data)
        }

        // Simulate multiple inputs
        view.insertText("a")
        view.insertText("b")
        view.insertText("c")

        XCTAssertEqual(allReceivedData, "abc".data(using: .utf8))
    }

    func testSpecialCharacterInput() {
        let view = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), app: nil)

        var receivedData: Data?
        view.onTextInput = { data in
            receivedData = data
        }

        // Test newline
        view.insertText("\n")
        XCTAssertEqual(receivedData, "\n".data(using: .utf8))

        // Test tab
        view.insertText("\t")
        XCTAssertEqual(receivedData, "\t".data(using: .utf8))
    }
}
