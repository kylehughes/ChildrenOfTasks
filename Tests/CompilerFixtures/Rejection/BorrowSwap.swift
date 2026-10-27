import ChildrenOfTasks

func invalid() async {
    await withChildren { outer in
        await withChildren {
            inner in swap(&outer, &inner)
        }
    }
}
