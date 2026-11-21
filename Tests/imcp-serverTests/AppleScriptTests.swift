import Foundation
import XCTest
import os

/// These scripts send no Apple events to other apps.
final class AppleScriptTests: XCTestCase {
    @MainActor
    func testScriptsRunOffTheMainThread() async throws {
        // Hold the serial queue. A script that ran on the main actor
        // would finish anyway; a script on the queue waits.
        let release = DispatchSemaphore(value: 0)
        NSAppleScript.executionQueue.async { release.wait() }

        let finished = OSAllocatedUnfairLock(initialState: false)
        let script = Task { @MainActor in
            defer { finished.withLock { $0 = true } }
            return try await NSAppleScript.execute("return 1 + 1").int32Value
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finished.withLock { $0 }, "the script did not wait for the queue")

        release.signal()
        let sum = try await script.value
        XCTAssertEqual(sum, 2)
    }

    func testCancelledTasksRunNoScript() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NSAppleScript.execute("return 2").int32Value
        }
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testCancellingAQueuedScriptStopsItBeforeItRuns() async throws {
        // Hold the serial queue, so that the script waits until after it is cancelled.
        let release = DispatchSemaphore(value: 0)
        NSAppleScript.executionQueue.async { release.wait() }

        let queued = Task { try await NSAppleScript.execute("return 2").int32Value }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        release.signal()

        do {
            let result = try await queued.value
            XCTFail("the queued script ran and returned \(result)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testHandlerReceivesInputAsData() async throws {
        let text = "quotes: \" and \\ and emoji 📝\nreturn false"
        let result = try await NSAppleScript.execute(
            "on echoText(theText)\nreturn theText\nend echoText",
            handler: "echoText",
            arguments: [text]
        )
        XCTAssertEqual(result.stringValue, text)
    }

    func testCancellingDuringAuthorizationPreventsExecution() async {
        let entered = expectation(description: "The script reached its pre-execution check")
        let release = DispatchSemaphore(value: 0)
        let script = Task {
            try await NSAppleScript.execute(
                "return true",
                beforeExecution: {
                    entered.fulfill()
                    release.wait()
                }
            ).booleanValue
        }
        await fulfillment(of: [entered], timeout: 5)
        script.cancel()
        release.signal()

        do {
            _ = try await script.value
            XCTFail("the cancelled script ran")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testScriptErrorsKeepTheirNumberAndMessage() async {
        do {
            _ = try await NSAppleScript.execute("error \"Not allowed.\" number -1743")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(
                error as? NSAppleScript.ExecutionError,
                NSAppleScript.ExecutionError(number: -1743, message: "Not allowed.")
            )
        }

        do {
            _ = try await NSAppleScript.execute("return (")
            XCTFail("expected a compile error")
        } catch {
            XCTAssertNotNil((error as? NSAppleScript.ExecutionError)?.number)
        }
    }

    func testAuthorizationCanRejectQueuedScript() async throws {
        struct Rejected: Error {}
        do {
            _ = try await NSAppleScript.execute("return true", beforeExecution: { throw Rejected() })
            XCTFail("expected authorization failure")
        } catch {
            XCTAssertTrue(error is Rejected)
        }
    }

    func testNotesBodyEscapesCallerText() {
        XCTAssertEqual(
            NotesCreation.noteBody(title: "A < B", text: "hello & goodbye\r\n<img src=x> 📝"),
            "<div>A &lt; B</div><div>hello &amp; goodbye<br>&lt;img src=x&gt; 📝</div>"
        )
    }

    func testNotesCreationToolsDefaultToDisabled() async throws {
        let inputs: [(Tool, [String: Value])] = [
            (
                NotesCreation.noteTool,
                [
                    "account": "Synthetic Account",
                    "folderPath": ["Synthetic Folder"],
                    "title": "Synthetic Note",
                    "text": "Synthetic text",
                ]
            ),
            (NotesCreation.folderTool, ["account": "Synthetic Account", "name": "Synthetic Folder"]),
        ]
        for (tool, arguments) in inputs {
            do {
                _ = try await tool(arguments)
                XCTFail("expected the Notes creation tool to be disabled")
            } catch {
                XCTAssertEqual(error.localizedDescription, "This Notes creation tool is off in iMCP settings.")
            }
        }
    }

    func testNotesDestinationComparisonIsExact() async throws {
        let match = try await NSAppleScript.execute(
            NotesCreation.script,
            handler: "exactName",
            arguments: ["Café - [test]", "Café - [test]"]
        )
        XCTAssertTrue(match.booleanValue)
        for different in ["café - [test]", "Cafe - [test]", "Café -[test]", "Café – [test]"] {
            let mismatch = try await NSAppleScript.execute(
                NotesCreation.script,
                handler: "exactName",
                arguments: ["Café - [test]", different]
            )
            XCTAssertFalse(mismatch.booleanValue)
        }
    }
}
