import Foundation

let args = CommandLine.arguments.map { URL(fileURLWithPath: $0) }
guard args.count == 5, let dictionary = MoyuDictionary(url: args[1].appendingPathComponent("moyu.dict")) else {
    print("历史词库或参数缺失")
    exit(2)
}
try runBenchmark(dictionary: dictionary, resources: args[1], corpus: args[2], blind: args[3], output: args[4])
