from quicksort import quicksort

def test_quicksort():
    assert quicksort([3, 6, 8, 10, 1, 2, 1]) == [1, 1, 2, 3, 6, 8, 10]
    assert quicksort([]) == []
    assert quicksort([1]) == [1]
    assert quicksort([5, 4, 3, 2, 1]) == [1, 2, 3, 4, 5]
    assert quicksort([1, 2, 3, 4, 5]) == [1, 2, 3, 4, 5]
    print("All tests passed!")

if __name__ == "__main__":
    test_quicksort()
