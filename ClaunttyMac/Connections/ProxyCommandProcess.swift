import Foundation

/// An ssh_config ProxyCommand, run as ssh runs it: through the shell, with `%h`,
/// `%p` and `%r` filled in. SSHConnection speaks SSH over its stdin and stdout.
final class ProxyCommandProcess {
    /// The command's stdout, to read SSH from; owned by the NIO channel
    let readDescriptor: Int32
    /// The command's stdin, to write SSH to; owned by the NIO channel
    let writeDescriptor: Int32
    private let process = Process()

    enum Failure: Error, LocalizedError {
        case launch(String, Error)
        var errorDescription: String? {
            switch self {
            case .launch(let command, let error): "Couldn't run ProxyCommand “\(command)”: \(error.localizedDescription)"
            }
        }
    }

    init(_ template: String, host: String, port: Int, user: String) throws {
        let command = Self.expand(template, host: host, port: port, user: user)
        let toCommand = Pipe(), fromCommand = Pipe()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-c", "exec \(command)"]
        process.standardInput = toCommand
        process.standardOutput = fromCommand
        process.standardError = FileHandle.nullDevice
        // An app started from the Dock has launchd's short PATH; add Homebrew's
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        do {
            try process.run()
        } catch {
            throw Failure.launch(command, error)
        }
        // The channel gets its own copies; the Pipes close theirs when they go away
        readDescriptor = dup(fromCommand.fileHandleForReading.fileDescriptor)
        writeDescriptor = dup(toCommand.fileHandleForWriting.fileDescriptor)
    }

    deinit {
        terminate()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// ssh's tokens: %h the host, %p the port, %r the user, %% a percent sign
    static func expand(_ template: String, host: String, port: Int, user: String) -> String {
        var out = ""
        var chars = template.makeIterator()
        while let c = chars.next() {
            guard c == "%", let token = chars.next() else {
                out.append(c)
                continue
            }
            switch token {
            case "h": out += host
            case "p": out += String(port)
            case "r": out += user
            case "%": out += "%"
            default: out += "%\(token)"
            }
        }
        return out
    }
}
