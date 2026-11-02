import CoreML
import Foundation

// Usage: compile-model <ReaderBlocks.mlmodel> <folder>. Xcode's compiler is not needed.
let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: CommandLine.arguments[1]))
let target = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("ReaderBlocks.mlmodelc")
try? FileManager.default.removeItem(at: target)
try FileManager.default.copyItem(at: compiled, to: target)
print(target.path)
