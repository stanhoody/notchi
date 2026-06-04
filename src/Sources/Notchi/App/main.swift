import AppKit

// SPM executable entry point. Equivalent to @NSApplicationMain for non-storyboard apps.

if CommandLine.arguments.contains("--install-hooks") {
    do {
        try HookInstaller.install()
        let s = HookInstaller.status()
        FileHandle.standardError.write(Data("Notchi hooks installed at \(s.path.path)\nregistered=\(s.settingsRegistered) scripts=\(s.scriptsPresent)\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--uninstall-hooks") {
    do {
        try HookInstaller.uninstall()
        FileHandle.standardError.write(Data("Notchi hooks uninstalled\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("uninstall failed: \(error)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--tokentest") {
    // --tokentest <cwd> <sessionID>
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--tokentest"), args.count > i + 2 {
        let s = TokenStats.read(cwd: args[i + 1], sessionID: args[i + 2])
        print("title=\(s.title ?? "nil")")
        print("model=\(s.model ?? "nil") in=\(s.input.map(String.init) ?? "nil") out=\(s.output.map(String.init) ?? "nil") cacheRead=\(s.cacheRead.map(String.init) ?? "nil") cacheWrite=\(s.cacheWrite.map(String.init) ?? "nil") hasTokens=\(s.hasTokens)")
        if let d = s.dollars(pricing: ModelPrice.table) { print(String(format: "est $%.2f (partial, last 1MB)", d)) }
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--export-assets") {
    let dir = (i + 1 < CommandLine.arguments.count && !CommandLine.arguments[i + 1].hasPrefix("-"))
        ? CommandLine.arguments[i + 1]
        : "~/Documents/Claude/Projects/Notchi/assets-preview"
    exit(AssetExporter.run(dir: dir))
}

if CommandLine.arguments.contains("--dumpsprite") {
    let arg = CommandLine.arguments.last ?? "idle"
    let anim: SpriteAnimation
    switch arg {
    case "waiting":   anim = .waiting
    case "attention": anim = .attention
    case "thinking":  anim = .thinking
    case "planning":  anim = .planning
    case "celebrate": anim = .celebrate
    case "confused":  anim = .confused
    case "sleeping":  anim = .sleeping
    case "edit":      anim = .working(.edit, tired: false)
    case "tired":     anim = .working(.edit, tired: true)
    case "bash":      anim = .working(.bash, tired: false)
    case "read":      anim = .working(.read, tired: false)
    case "web":       anim = .working(.web, tired: false)
    case "other":     anim = .working(.other, tired: false)
    default:          anim = .idleStatic
    }
    print(SpriteCompositor.ascii(anim, frames: 4))
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    // Headless logic check (no Xcode/XCTest on this machine). Runs and exits.
    let sem = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task {
        code = await SelfTest.run()
        sem.signal()
    }
    sem.wait()
    exit(code)
}

// `main.swift` runs synchronously on the main thread; assume MainActor isolation so we can
// construct the @MainActor AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
