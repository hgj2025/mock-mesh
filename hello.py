def quick_sort(arr):
    if len(arr) <= 1:
        return arr
    
    pivot = arr[len(arr) - 1]
    left = []
    right = []
    
    for i in range(len(arr) - 1):
        if arr[i] < pivot:
            left.append(arr[i])
        else:
            right.append(arr[i])
    
    return quick_sort(left) + [pivot] + quick_sort(right)


unsorted_array = [5, 3, 7, 6, 2, 9]
sorted_array = quick_sort(unsorted_array)

print("未排序数组:", unsorted_array)
print("排序后数组:", sorted_array)
