import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var assertions = 0

struct Missing: Error {}

func expect(_ ok: @autoclosure () async throws -> Bool, _ note: String = "", file: String = #fileID, line: Int = #line) async throws {
    assertions += 1
    if try await !ok() {
        failures += 1
        print("  FAIL \(file):\(line) \(note)")
    }
}

func require<T>(_ v: T?, file: String = #fileID, line: Int = #line) throws -> T {
    guard let v else {
        print("  FAIL \(file):\(line) value was nil")
        throw Missing()
    }
    return v
}

func expectThrows<E: Error & Equatable, T>(_ expected: E, _ note: String = "", file: String = #fileID, line: Int = #line, _ body: () async throws -> T) async {
    assertions += 1
    do {
        _ = try await body()
        failures += 1
        print("  FAIL \(file):\(line) did not throw \(expected) \(note)")
    } catch let e as E where e == expected {
    } catch {
        failures += 1
        print("  FAIL \(file):\(line) threw \(error), wanted \(expected) \(note)")
    }
}

func run(_ name: String, _ body: () async throws -> Void) async {
    let before = failures
    do { try await body() } catch {
        failures += 1
        print("  FAIL \(name) threw \(error)")
    }
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}
