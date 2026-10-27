import ChildrenOfTasks

actor Receiver {
    func read(_ child: Child<Int, Never>) async -> Int {
        await child.value()
    }
}
func valid(_ receiver: Receiver) async {
    await withChildren { (children: borrowing Children) in
        let child = children.start {
            7
        }

        let task = Task {
            await child.value()
        }

        async let value = child.value()
        _ = await task.value
        _ = await value
        _ = await receiver.read(child)
    }
}
