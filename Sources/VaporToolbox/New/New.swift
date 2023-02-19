import ConsoleKit
import Foundation
import Yams

struct New: AnyCommand {
    struct Signature: CommandSignature {
        @Argument(name: "name", help: "Name of project and folder.")
        var name: String
        
        @Option(name: "template", short: "T", help: "The URL of a Git repository to use as a template.")
        var templateURL: String?
        
        @Option(name: "branch", help: "Template repository branch to use.")
        var templateBranch: String?
        
        @Option(name: "output", short: "o", help: "The directory to place the new project in.")
        var outputDirectory: String?

        @Option(name: "conflict-strategy", help: "The method by which file conflicts should be resolved if --output is set")
        var conflictStrategy: ConflictResolutionStrategy?
        
        @Flag(name: "no-commit", help: "Skips adding a first commit to the newly created repo.")
        var noCommit: Bool
        
        @Flag(name: "no-git", help: "Skips adding a Git repository to the project folder.")
        var noGit: Bool
    }

    let help = "Generates a new app."

    func outputHelp(using context: inout CommandContext) {
        Signature().outputHelp(help: self.help, using: &context)
    }

    func run(using context: inout CommandContext) throws {
        let signature = try Signature(from: &context.input)
        let name = signature.name
        let gitUrl = signature.templateURL ?? "https://github.com/vapor/template"
        let fileManager = FileManager.default
        let cwd = fileManager.currentDirectoryPath
        let workTree = signature.outputDirectory?.asDirectoryURL.path ?? cwd.appendingPathComponents(name)
        let templateTree = workTree.deletingLastPathComponents().appendingPathComponents(".vapor-template")

        let conflictStrategy = signature.conflictStrategy ?? .error

        let originalDelegate = fileManager.delegate
        let newDelegate = ConflictResolvingFileManagerDelegate(conflictStrategy: conflictStrategy, console: context.console)
        fileManager.delegate = newDelegate
        defer {
            fileManager.delegate = originalDelegate
        }

        context.console.info("Cloning template...")
        try? fileManager.removeItem(atPath: templateTree)
        let gitBranch = signature.templateBranch ?? "main"
        _ = try Process.git.clone(repo: gitUrl, toFolder: templateTree, branch: gitBranch)

        do {
            try fileManager.createDirectory(atPath: workTree, withIntermediateDirectories: false, attributes: nil)
        } catch let error as NSError where signature.$outputDirectory.isPresent && error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
            // If the user specified an existing directory as the output path, we can just use it for the new project root
        }

        if fileManager.fileExists(atPath: templateTree.appendingPathComponents("manifest.yml")) {

            let yaml = try String(contentsOf: templateTree.appendingPathComponents("manifest.yml").asFileURL, encoding: .utf8)
            let manifest = try YAMLDecoder().decode(TemplateManifest.self, from: yaml)
            let scaffolder = TemplateScaffolder(console: context.console, manifest: manifest)
            try scaffolder.scaffold(
                name: name, 
                from: templateTree.trailingSlash, 
                to: workTree.trailingSlash,
                using: &context.input,
                fileManager: fileManager
            )
            try fileManager.removeItem(atPath: templateTree)
        } else {
            let template: URL
            let output: URL

            if #available(macOS 13, *) {
                template = URL(filePath: templateTree, directoryHint: .isDirectory)
                output = URL(filePath: workTree, directoryHint: .isDirectory)
            } else {
                template = URL(fileURLWithPath: templateTree, isDirectory: true)
                output = URL(fileURLWithPath: workTree, isDirectory: true)
            }

            try fileManager.moveDirectory(at: template, to: output)
        }

        guard context.input.arguments.isEmpty else {
            throw "Too many arguments: \(context.input.arguments.joined(separator: " "))"
        }
        
        if !signature.noGit {
            // clear existing git history
            let gitDir = workTree.appendingPathComponents(".git")
            
            context.console.info("Creating git repository")
            if fileManager.fileExists(atPath: gitDir) && signature.$outputDirectory.isPresent {
                try fileManager.removeItem(atPath: gitDir)
            }
            _ = try Process.git.create(gitDir: gitDir)
            
            // first commit
            if !signature.noCommit {
                context.console.info("Adding first commit")
                try Process.git.commit(gitDir: gitDir, workTree: workTree, msg: "first commit")
            }
        }
        
        // print the Droplet
        var copy = context
        try PrintDroplet().run(using: &copy)
        
        // figure out the shortest relative path to the new project
        var cdInstruction = workTree.lastPathComponent
        switch workTree.deletingLastPathComponents(1).commonPrefix(with: cwd).trailingSlash {
            case cwd.trailingSlash: // is in current directory
                break
            case cwd.deletingLastPathComponents(1).trailingSlash: // reachable from one level up
                cdInstruction = "..".appendingPathComponents(workTree.pathComponents.suffix(1))
            case cwd.deletingLastPathComponents(2).trailingSlash: // reachable from two levels up
                cdInstruction = "../..".appendingPathComponents(workTree.pathComponents.suffix(2))
            default: // too distant to be worth expressing as a relative path
                cdInstruction = workTree
        }
        
        // print info
        context.console.center([
            "Project " + name.consoleText(.info) + " has been created!",
            "",
            "Use " + "cd \(Process.shell.escapeshellarg(cdInstruction))".consoleText(.info) + " to enter the project directory",
            "Then open your project, for example if using Xcode type " + "open Package.swift".consoleText(.info) + " or " + "code .".consoleText(.info) + " if using VSCode",
        ]).forEach { context.console.output($0) }
    }

    private class ConflictResolvingFileManagerDelegate: NSObject, FileManagerDelegate {
        let conflictStrategy: ConflictResolutionStrategy
        let console: Console

        init(conflictStrategy: ConflictResolutionStrategy, console: Console) {
            self.conflictStrategy = conflictStrategy
            self.console = console
            super.init()
        }

        func fileManager(_ manager: FileManager, shouldMoveItemAt source: URL, to destination: URL) -> Bool {

            guard !source.isDirectory else {

                // By default, the system only asks if a directory should be move and none of its children, so we have to move them ourselves if we want those hooks

                do {
                    try manager.moveDirectory(at: source, to: destination)
                } catch {
                    // Since move errors are already suppressed by this delegate, crashing is the only appropriate thing to do here to avoid data loss
                    fatalError(error.localizedDescription)
                }

                return false
            }

            let destinationPath: String

            if #available(macOS 13, *) {
                destinationPath = destination.path(percentEncoded: false)
            } else {
                destinationPath = destination.path
            }

            switch conflictStrategy {
            case .keepExisting:
                return !manager.fileExists(atPath: destinationPath)
            case .overwrite, .error: // Errors are handled in the error handler
                return true
            }
        }

        func fileManager(_ manager: FileManager, shouldProceedAfterError rawError: Error, movingItemAt source: URL, to destination: URL) -> Bool {

            let error = rawError as NSError
            guard error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError else {
                return false
            }

            guard source.isDirectory == destination.isDirectory || destination.isDirectory && (try? manager.contentsOfDirectory(at: destination, includingPropertiesForKeys: []))?.isEmpty == true else {
                // If one is a directory and the other is not, that's a problem
                // However, if the destination is an empty directory, that's fine
                return false
            }

            switch conflictStrategy {
            case .overwrite:
                return true
            case .error, .keepExisting: // If we've made it this far with .keepExisting, the implementation of fileManager(_:shouldMoveItemAt:to:) is broken, and we should crash
                return false
            }
        }
    }
}

enum ConflictResolutionStrategy: String, LosslessStringConvertible {
        case error
        case keepExisting = "keep-existing"
        case overwrite

        init?(_ description: String) {
            self.init(rawValue: description)
        }

        var description: String {
            rawValue
        }
    }

struct PrintDroplet: Command {
    struct Signature: CommandSignature {}
    let signature = Signature()
    let help = "prints a droplet."
    
    func run(using ctx: CommandContext, signature: Signature) throws {
        for line in ctx.console.center(asciiArt) {
            for character in line {
                let style: ConsoleStyle
                if let color = colors[character] {
                    style = ConsoleStyle(color: color, background: nil, isBold: false)
                } else {
                    style = .plain
                }
                ctx.console.output(character.description, style: style, newLine: false)
            }
            ctx.console.output("", style: .plain, newLine: true)
        }
    }


    private let asciiArt: [String] = [
        "                                ",
        "               **               ",
        "             **~~**             ",
        "           **~~~~~~**           ",
        "         **~~~~~~~~~~**         ",
        "       **~~~~~~~~~~~~~~**       ",
        "     **~~~~~~~~~~~~~~~~~~**     ",
        "   **~~~~~~~~~~~~~~~~~~~~~~**   ",
        "  **~~~~~~~~~~~~~~~~~~~~~~~~**  ",
        " **~~~~~~~~~~~~~~~~~~~~~~~~~~** ",
        "**~~~~~~~~~~~~~~~~~~~~~~~~~~~~**",
        "**~~~~~~~~~~~~~~~~~~~~~~~~~~~~**",
        "**~~~~~~~~~~~~~~~~~~~~~++++~~~**",
        " **~~~~~~~~~~~~~~~~~~~++++~~~** ",
        "  ***~~~~~~~~~~~~~~~++++~~~***  ",
        "    ****~~~~~~~~~~++++~~****    ",
        "       *****~~~~~~~~~*****      ",
        "          *************         ",
        "                                ",
        " _       __    ___   ___   ___  ",
        // the escaping `\` make these lines look weird,
        // but they're correct
        "\\ \\  /  / /\\  | |_) / / \\ | |_) ",
        " \\_\\/  /_/--\\ |_|   \\_\\_/ |_| \\ ",
        "   a web framework for Swift    ",
        "                                "
    ]

    private let colors: [Character: ConsoleColor] = [
        "*": .magenta,
        "~": .blue,
        "+": .cyan, // Droplet
        "_": .magenta,
        "/": .magenta,
        "\\": .magenta,
        "|": .magenta,
        "-": .magenta,
        ")": .magenta // Title
    ]
}

extension Console {
    func center(_ strings: [ConsoleText], padding: String = " ") -> [ConsoleText] {
        var lines = strings

        // Make sure there's more than one line
        guard lines.count > 0 else {
            return []
        }

        // Find the longest line
        var longestLine = 0
        for line in lines {
            if line.description.count > longestLine {
                longestLine = line.description.count
            }
        }

        // Calculate the padding and make sure it's greater than or equal to 0
        let minPaddingCount = max(0, (size.width - longestLine) / 2)

        // Apply the padding to each line
        for i in 0..<lines.count {
            let diff = (longestLine - lines[i].description.count) / 2
            for _ in 0..<(minPaddingCount + diff) {
                lines[i].fragments.insert(.init(string: padding), at: 0)
            }
        }

        return lines
    }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

extension FileManager {
    func createDirectory(at location: URL) throws {
        do {
            try createDirectory(at: location, withIntermediateDirectories: false)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
            // If a directory already exists, we can just use it

            guard location.isDirectory else {
                throw error
            }
        }
    }

    func moveDirectory(at source: URL, to destination: URL) throws {
        let sourceContents = try contentsOfDirectory(at: source, includingPropertiesForKeys: [])

        try createDirectory(at: destination)

        for itemSource in sourceContents {
            let itemDestination: URL

            if #available(macOS 13, *) {
                itemDestination = destination.appending(component: source.lastPathComponent, directoryHint: .checkFileSystem)
            } else {
                itemDestination = destination.appendingPathComponent(source.lastPathComponent)
            }

            try moveItem(at: itemSource, to: itemDestination)
        }
    }
}
