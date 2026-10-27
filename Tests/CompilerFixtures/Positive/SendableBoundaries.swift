import ChildrenOfTasks

struct Payload: Sendable {
    let value: Int
}
func valid(_ payload: Payload) async {
    await withChildren { (children: borrowing Children) in
        let result: Child<Payload, Never> = children.start {
            payload
        }
        let captured: Child<Int, Never> = children.start {
            payload.value
        }
        _ = await result.value()
        _ = await captured.value()
    }
}
