import Foundation
import Testing
@testable import TokenjarCore

/// The shim text is cmd-shim's, as npm writes it on Windows; parsing it is plain text, so this runs everywhere.
struct NpmShimTests {
    private let folder = URL(fileURLWithPath: "/npm")

    private func shim(_ entry: String, crlf: Bool = true) -> String {
        let lines = [
            "@ECHO off", "GOTO start", ":find_dp0", "SET dp0=%~dp0", "EXIT /b", ":start", "SETLOCAL", "CALL :find_dp0", "",
            #"IF EXIST "%dp0%\node.exe" ("#, #"  SET "_prog=%dp0%\node.exe""#, ") ELSE (", #"  SET "_prog=node""#,
            "  SET PATHEXT=%PATHEXT:;.JS;=;%", ")", "",
            #"endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "\#(entry)" %*"#,
        ]
        return lines.joined(separator: crlf ? "\r\n" : "\n") + (crlf ? "\r\n" : "\n")
    }

    @Test func aScriptEntryRunsUnderNode() {
        #expect(NpmShim.target(of: shim(#"%dp0%\node_modules\@anthropic-ai\claude-code\cli.js"#), in: folder)
            == .node(script: URL(fileURLWithPath: "/npm/node_modules/@anthropic-ai/claude-code/cli.js")))
        #expect(NpmShim.target(of: shim(#"%dp0%\node_modules\@openai\codex\bin\codex.js"#, crlf: false), in: folder)
            == .node(script: URL(fileURLWithPath: "/npm/node_modules/@openai/codex/bin/codex.js")))
    }

    @Test func olderShimsNameTheirFolderWithTilde() {
        let old = #"@"%~dp0\node_modules\opencode-ai\bin\opencode" %*"# + "\r\n"
        #expect(NpmShim.target(of: old, in: folder) == .node(script: URL(fileURLWithPath: "/npm/node_modules/opencode-ai/bin/opencode")))
    }

    @Test func aProgramEntryRunsDirectly() {
        #expect(NpmShim.target(of: shim(#"%dp0%\..\tools\gh.exe"#), in: folder) == .program(URL(fileURLWithPath: "/tools/gh.exe")))
    }

    @Test func anythingElseIsNotRead() {
        #expect(NpmShim.target(of: "@echo hi\r\n", in: folder) == nil)
        #expect(NpmShim.target(of: shim(#"%dp0%\node_modules\x\run.ps1"#), in: folder) == nil)
        #expect(NpmShim.target(of: "", in: folder) == nil)
    }
}
