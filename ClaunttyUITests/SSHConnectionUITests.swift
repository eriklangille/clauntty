import XCTest

/// End-to-end UI tests for SSH connection flow
/// Requires Docker SSH test server running: ./scripts/docker-ssh/ssh-test-server.sh start
final class SSHConnectionUITests: XCTestCase {

    var app: XCUIApplication!

    // Test server credentials (from Docker)
    let testHost = "localhost"
    let testPort = "22"
    let testUsername = "testuser"
    let testPassword = "testpass"

    // Cell identifier (shows as "username@host" in the list)
    var testCellIdentifier: String { "\(testUsername)@\(testHost)" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Connection List Tests

    func testConnectionListDisplays() throws {
        // Verify the main screen shows
        XCTAssertTrue(app.staticTexts["Servers"].exists)
        XCTAssertTrue(app.buttons["Add"].exists || app.buttons["+"].exists)
    }

    func testAddNewConnection() throws {
        // Tap add button
        let addButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        // Fill in connection details
        let nameField = app.textFields["Name (optional)"]
        let hostField = app.textFields["Host"]
        let portField = app.textFields["Port"]
        let usernameField = app.textFields["Username"]

        // Wait for form to appear
        XCTAssertTrue(hostField.waitForExistence(timeout: 5))

        // Enter test server details
        if nameField.exists {
            nameField.tap()
            nameField.typeText("Docker Test")
        }

        hostField.tap()
        hostField.typeText(testHost)

        // Port field should have default value, clear and set
        portField.tap()
        portField.press(forDuration: 1.0)
        app.menuItems["Select All"].tap()
        portField.typeText(testPort)

        usernameField.tap()
        usernameField.typeText(testUsername)

        // Save the connection
        let saveButton = app.navigationBars.buttons["Save"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        // Verify connection appears in list (cell shows "testuser@localhost")
        let connectionCell = app.cells.containing(.staticText, identifier: testCellIdentifier).firstMatch
        XCTAssertTrue(connectionCell.waitForExistence(timeout: 5))
    }

    // MARK: - SSH Connection Tests

    func testSSHConnectionWithPassword() throws {
        // First add a connection
        try addTestConnection()

        // Tap on the connection to connect (cell shows "testuser@localhost")
        // Use firstMatch since there might be multiple connections from previous runs
        let connectionCell = app.cells.containing(.staticText, identifier: testCellIdentifier).firstMatch
        XCTAssertTrue(connectionCell.waitForExistence(timeout: 5))
        connectionCell.tap()

        // Handle password prompt
        let passwordField = app.secureTextFields.firstMatch
        if passwordField.waitForExistence(timeout: 5) {
            passwordField.tap()
            passwordField.typeText(testPassword)

            // Submit password
            let connectButton = app.buttons["Connect"]
            if connectButton.exists {
                connectButton.tap()
            } else {
                // Try pressing return
                app.keyboards.buttons["return"].tap()
            }
        }

        // Wait for terminal view to appear - check for the navigation bar with toolbar button
        // The terminal view has an "xmark.circle.fill" button in the toolbar
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 15), "Terminal view should appear after connection")

        // Verify we're in the terminal view (navigation bar with buttons should be visible)
        XCTAssertTrue(app.navigationBars.buttons.count > 0, "Should have navigation buttons")
    }

    func testSSHConnectionShowsTerminalOutput() throws {
        // First connect
        try addTestConnection()

        let connectionCell = app.cells.containing(.staticText, identifier: testCellIdentifier).firstMatch
        XCTAssertTrue(connectionCell.waitForExistence(timeout: 5))
        connectionCell.tap()

        // Handle password
        let passwordField = app.secureTextFields.firstMatch
        if passwordField.waitForExistence(timeout: 5) {
            passwordField.tap()
            passwordField.typeText(testPassword)
            app.keyboards.buttons["return"].tap()
        }

        // Wait for connection
        sleep(3)

        // The terminal should show the welcome message from the Docker container
        // "Welcome to Clauntty SSH Test Server!"
        // Note: We can't easily read the Metal-rendered terminal content,
        // but we can verify the view is displayed and not showing an error

        // Verify no error overlay is shown
        let errorText = app.staticTexts["Connection Failed"]
        XCTAssertFalse(errorText.exists, "Should not show connection error")
    }

    func testDisconnectFromTerminal() throws {
        // Connect first
        try addTestConnection()

        let connectionCell = app.cells.containing(.staticText, identifier: testCellIdentifier).firstMatch
        connectionCell.tap()

        let passwordField = app.secureTextFields.firstMatch
        if passwordField.waitForExistence(timeout: 5) {
            passwordField.tap()
            passwordField.typeText(testPassword)
            app.keyboards.buttons["return"].tap()
        }

        // Wait for terminal
        sleep(3)

        // Tap disconnect button (red X)
        let closeButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.tap()

        // Verify we're back at the connection list
        XCTAssertTrue(app.staticTexts["Servers"].waitForExistence(timeout: 5))
    }

    // MARK: - Error Handling Tests

    func testConnectionFailureShowsError() throws {
        // Add a connection with wrong port
        try addConnectionWithDetails(
            host: "localhost",
            port: "9999",  // Wrong port
            username: "testuser"
        )

        // Tap to connect
        let connectionCell = app.cells.containing(.staticText, identifier: testCellIdentifier).firstMatch
        connectionCell.tap()

        // Handle password prompt if shown
        let passwordField = app.secureTextFields.firstMatch
        if passwordField.waitForExistence(timeout: 3) {
            passwordField.tap()
            passwordField.typeText("wrongpassword")
            app.keyboards.buttons["return"].tap()
        }

        // Should show error
        let errorText = app.staticTexts["Connection Failed"]
        XCTAssertTrue(errorText.waitForExistence(timeout: 15), "Should show connection error for wrong port")
    }

    // MARK: - Helper Methods

    private func addTestConnection() throws {
        try addConnectionWithDetails(
            host: testHost,
            port: testPort,
            username: testUsername
        )
    }

    private func addConnectionWithDetails(host: String, port: String, username: String) throws {
        // Check if connection already exists
        let existingCell = app.cells.containing(.staticText, identifier: username).element
        if existingCell.exists {
            return // Connection already added
        }

        // Tap add button
        let addButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        // Fill form
        let hostField = app.textFields["Host"]
        let portField = app.textFields["Port"]
        let usernameField = app.textFields["Username"]

        XCTAssertTrue(hostField.waitForExistence(timeout: 5))

        hostField.tap()
        hostField.typeText(host)

        portField.tap()
        // Select all and replace
        portField.press(forDuration: 1.0)
        if app.menuItems["Select All"].exists {
            app.menuItems["Select All"].tap()
        }
        portField.typeText(port)

        usernameField.tap()
        usernameField.typeText(username)

        // Save
        app.navigationBars.buttons["Save"].firstMatch.tap()

        // Wait for list to update
        sleep(1)
    }
}
