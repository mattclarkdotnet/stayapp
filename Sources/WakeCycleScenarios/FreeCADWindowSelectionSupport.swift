import ApplicationServices
import Foundation

// Design intent: isolate FreeCAD-specific child-window selection heuristics
// from the generic prepare/verify orchestration flow.
extension WakeCycleScenarioRunner {
    func selectFreeCADScenarioWindows(pid: Int32) -> (
        main: LiveWindow, children: [(panel: FreeCADChildPanel, window: LiveWindow)]
    )? {
        let windows = liveWindows(pid: pid)
        guard windows.count >= 5 else {
            return nil
        }

        var remaining = windows
        var children: [(panel: FreeCADChildPanel, window: LiveWindow)] = []
        children.reserveCapacity(FreeCADChildPanel.allCases.count)

        for panel in FreeCADChildPanel.allCases {
            guard let best = bestFreeCADChildWindow(for: panel, in: remaining) else {
                return nil
            }
            children.append((panel: panel, window: best))
            remaining.removeAll(where: { candidate in
                CFEqual(candidate.element, best.element)
            })
        }

        guard let main = chooseFreeCADMainWindow(from: remaining) else {
            return nil
        }

        return (main: main, children: children)
    }

    func chooseFreeCADMainWindow(from windows: [LiveWindow]) -> LiveWindow? {
        guard !windows.isEmpty else {
            return nil
        }
        let titled = windows.filter { normalized($0.title)?.contains("freecad") == true }
        let pool = titled.isEmpty ? windows : titled
        return pool.max(by: { windowArea($0.frame) < windowArea($1.frame) })
    }

    func bestFreeCADChildWindow(for panel: FreeCADChildPanel, in windows: [LiveWindow])
        -> LiveWindow?
    {
        let ranked = windows.compactMap { window -> (window: LiveWindow, score: Int)? in
            let score = freeCADChildWindowScore(window: window, panel: panel)
            guard score > 0 else {
                return nil
            }
            return (window: window, score: score)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            let lhsArea = windowArea(lhs.window.frame)
            let rhsArea = windowArea(rhs.window.frame)
            if lhsArea != rhsArea {
                return lhsArea > rhsArea
            }
            if lhs.window.number != rhs.window.number {
                return (lhs.window.number ?? Int.max) < (rhs.window.number ?? Int.max)
            }
            if lhs.window.frame.minX != rhs.window.frame.minX {
                return lhs.window.frame.minX < rhs.window.frame.minX
            }
            return lhs.window.frame.minY < rhs.window.frame.minY
        }
        return ranked.first?.window
    }

    func freeCADChildWindowScore(window: LiveWindow, panel: FreeCADChildPanel) -> Int {
        guard
            let title = normalized(window.title)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return 0
        }
        var score = 0
        if title == panel.rawValue {
            score += 6
        }
        for keyword in panel.matchKeywords where title.contains(keyword) {
            score += 2
        }
        return score
    }

    func waitForWindows(
        pid: Int32,
        timeout: TimeInterval,
        condition: ([LiveWindow]) -> Bool
    ) throws -> [LiveWindow] {
        var result: [LiveWindow] = []
        let satisfied = waitUntil(timeout: timeout) {
            let current = liveWindows(pid: pid)
            if condition(current) {
                result = current
                return true
            }
            return false
        }
        if !satisfied {
            throw RunnerError.failed("timed out waiting for windows")
        }
        return result
    }
}
