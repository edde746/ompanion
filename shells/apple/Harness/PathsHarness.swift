import AppKit
import XCTest

/// The user of the macOS smoke run's `paths` check (smoke.sh; docs/contracts/bridge.md, Smoke runs): copies
/// PATHS/a.txt and PATHS/sub, prints `HARNESS copied`, then acts on each `SMOKE-STEP <step>` line the app writes to the
/// file LOG until SMOKE-DONE: chooses a.txt and b.txt in the open panel (`pick-files`), sub in the folder panel
/// (`pick-folder`), and for `drop` selects a.txt and sub in a Finder window and prints `HARNESS drag <x> <y> <x2> <y2>`:
/// smoke.sh drags from there onto the app's window (drag.js). A UI test, so it acts in the logged-in user's session, as
/// the app runs: its pasteboard, its windows. Xcode's test runner is sandboxed with read-only access to the disk, so it
/// writes no file, and may not post mouse events: XCUITest's own press-and-drag starts no drag in Finder.
final class PathsHarness: XCTestCase {
    /// Made when a step needs it: LaunchServices knows the app only once smoke.sh has opened it.
    private var app: XCUIApplication { XCUIApplication(bundleIdentifier: "com.edde746.ompanion") }

    /// The Finder window the drop step opened, closed at the end.
    private var finderWindow: XCUIElement?

    func testPaths() throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try XCTUnwrap(environment["PATHS"]), isDirectory: true)
        let log = try XCTUnwrap(environment["LOG"])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([
            folder.appendingPathComponent("a.txt") as NSURL,
            folder.appendingPathComponent("sub", isDirectory: true) as NSURL,
        ])
        defer {
            pasteboard.clearContents()
            finderWindow?.typeKey("w", modifierFlags: .command)
        }
        say("HARNESS copied")

        var done: Set<String> = []
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            if text.contains("SMOKE-DONE") { return }
            for line in text.split(separator: "\n") where line.hasPrefix("SMOKE-STEP ") {
                let step = String(line.dropFirst("SMOKE-STEP ".count))
                guard done.insert(step).inserted else { continue }
                say("HARNESS step \(step)")
                switch step {
                case "pick-files": try choose(["a.txt", "b.txt"])
                case "pick-folder": try choose(["sub"])
                case "drop": try prepareDrag(["a.txt", "sub"], in: folder)
                default: XCTFail("unknown step \(step)")
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("no SMOKE-DONE in \(log) after 4 minutes")
    }

    /// Selects `names` in the open panel (the window's sheet, which starts in the folder) and clicks Open. The panel is
    /// put in list view first: its column view leaves the folder's column scrolled out of the sheet.
    private func choose(_ names: [String]) throws {
        let sheet = app.sheets.firstMatch
        XCTAssert(sheet.waitForExistence(timeout: 20), "no open panel")
        sheet.typeKey("2", modifierFlags: .command)
        try select(names, in: sheet)
        sheet.buttons["Open"].click()
    }

    /// Opens the folder in Finder, selects `names` there and prints where a drag of them starts and where it ends: a
    /// part of the app's window that the Finder window leaves free. Accessibility frames and Quartz events share their
    /// coordinates (points from the main display's top left).
    private func prepareDrag(_ names: [String], in folder: URL) throws {
        XCTAssert(NSWorkspace.shared.open(folder), "Finder did not open \(folder.path)")
        let window = XCUIApplication(bundleIdentifier: "com.apple.finder").windows[folder.lastPathComponent]
        XCTAssert(window.waitForExistence(timeout: 20), "no Finder window of \(folder.path)")
        finderWindow = window
        let first = try select(names, in: window)
        let frame = app.windows.firstMatch.frame, covered = window.frame
        let points = [(0.5, 0.5), (0.15, 0.5), (0.85, 0.5), (0.5, 0.85), (0.15, 0.85), (0.85, 0.85), (0.5, 0.25)].map {
            CGPoint(x: frame.minX + frame.width * $0.0, y: frame.minY + frame.height * $0.1)
        }
        let end = try XCTUnwrap(
            points.first { !covered.contains($0) }, "the Finder window \(covered) covers the app's window \(frame)")
        say("HARNESS drag \(Int(first.frame.midX)) \(Int(first.frame.midY)) \(Int(end.x)) \(Int(end.y))")
    }

    /// Clicks the first of `names` in `container`, Command-clicks the others; returns the first. An item is the first
    /// text (lists) or image (Finder's icon view) of that name the pointer can reach: the panel's column view also
    /// names hidden columns after it.
    @discardableResult
    private func select(_ names: [String], in container: XCUIElement) throws -> XCUIElement {
        var items: [XCUIElement] = []
        let types: [XCUIElement.ElementType] = [.textField, .staticText, .image]
        for name in names {
            let candidates = container.descendants(matching: .any).matching(
                NSPredicate(
                    format: "elementType IN %@ AND (value == %@ OR label == %@ OR title == %@)",
                    types.map { NSNumber(value: $0.rawValue) } as NSArray, name, name, name))
            let deadline = Date().addingTimeInterval(10)
            var item: XCUIElement?
            while item == nil, Date() < deadline {
                item = candidates.allElementsBoundByIndex.first { $0.isHittable }
                if item == nil { Thread.sleep(forTimeInterval: 0.5) }
            }
            if item == nil { say(container.debugDescription) }
            let found = try XCTUnwrap(item, "no \(name) the pointer can reach in \(container)")
            if items.isEmpty {
                found.click()
            } else {
                XCUIElement.perform(withKeyModifiers: .command) { found.click() }
            }
            items.append(found)
        }
        return items[0]
    }

    /// A line on the output smoke.sh reads while the test runs: a pipe, which stdout would otherwise buffer.
    private func say(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
