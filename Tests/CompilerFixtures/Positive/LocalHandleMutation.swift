import ChildrenOfTasks

func consume(_ child: consuming Child<Int, Never>) {
}
func valid() async {
    await withChildren { (outer: borrowing Children) in
        var first = outer.start {
            1
        }
        var second = outer.start {
            2
        }
        swap(&first, &second)
        first = second
        consume(first)
    }
}
