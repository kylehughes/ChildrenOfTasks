import ChildrenOfTasks

enum Failure: Error {
    case failed
}
struct Payload: Sendable {
    let value: Int
}
func valid() async throws(Failure) -> Int {
    try await withChildren { (children: borrowing Children) throws(Failure) in
        let child: Child<Payload, Failure> = children.start {
            () throws(Failure) in Payload(value: 7)
        }
        return try await child.value().value
    }
}
