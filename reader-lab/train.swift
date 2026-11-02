import CoreML
import CreateML
import Foundation
import TabularData

// Boosted trees on block features. Every prediction used for scoring comes from a
// model that never saw that site; the shipped model then trains on all sites.
@main struct Train {
    static func batch(_ frame: DataFrame, _ names: [String]) throws -> MLArrayBatchProvider {
        var providers: [MLFeatureProvider] = []
        for row in frame.rows {
            var values: [String: Any] = [:]
            for name in names { values[name] = row[name, Double.self] ?? 0 }
            providers.append(try MLDictionaryFeatureProvider(dictionary: values))
        }
        return MLArrayBatchProvider(array: providers)
    }

    static func main() throws {
        let dest = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw = try DataFrame(contentsOfCSVFile: dest.appendingPathComponent("rows.csv"))
        let names = raw.columns.map(\.name).filter { !["fold", "page", "block", "label"].contains($0) }
        var table = raw
        for name in names where table[name].wrappedElementType == Int.self {
            let values = table[name, Int.self].map { $0.map(Double.init) }
            table.removeColumn(name)
            table.append(column: Column(name: name, contents: Array(values)))
        }
        let parameters = MLBoostedTreeClassifier.ModelParameters(validation: .none, maxDepth: 6, maxIterations: 120, stepSize: 0.2, rowSubsample: 0.8, columnSubsample: 0.8)
        var lines = ["page,block,score"]
        for fold in Set(table["fold", Int.self].compactMap { $0 }).sorted() {
            let train = DataFrame(table.filter(on: "fold", Int.self) { $0 != fold }).selecting(columnNames: ["label"] + names)
            let test = DataFrame(table.filter(on: "fold", Int.self) { $0 == fold })
            let model = try MLBoostedTreeClassifier(trainingData: train, targetColumn: "label", featureColumns: names, parameters: parameters)
            let output = try model.model.predictions(fromBatch: try batch(test, names))
            let pages = test["page", Int.self], blocks = test["block", Int.self]
            for row in 0..<output.count {
                let probabilities = output.features(at: row).featureValue(for: "labelProbability")?.dictionaryValue as? [Int64: NSNumber] ?? [:]
                lines.append("\(pages[row]!),\(blocks[row]!),\(probabilities[1]?.doubleValue ?? 0)")
            }
            print("fold", fold, "train", train.rows.count, "test", test.rows.count); fflush(stdout)
        }
        try lines.joined(separator: "\n").write(to: dest.appendingPathComponent("scores.csv"), atomically: true, encoding: .utf8)
        let final = try MLBoostedTreeClassifier(trainingData: table.selecting(columnNames: ["label"] + names), targetColumn: "label", featureColumns: names, parameters: parameters)
        try final.write(to: dest.appendingPathComponent("ReaderBlocks.mlmodel"), metadata: MLModelMetadata(author: "Apsa Browser", shortDescription: "Is this block of a page its main content?", version: "1"))
        print("final model written")
    }
}
