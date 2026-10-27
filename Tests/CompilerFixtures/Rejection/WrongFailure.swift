import ChildrenOfTasks

enum First: Error {
    case failed
}
enum Second: Error {
    case failed
}
func operation() async throws(First) -> Int {
    throw .failed
}
func invalid() async {
    await withChildren { (children: borrowing Children) in
        let child: Child<Int, Second> = children.start(operation)
        _ = child
    }
}
