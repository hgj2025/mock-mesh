function quickSort(arr) {
  if (arr.length <= 1) {
    return arr;
  }

  const pivot = arr[arr.length - 1];
  const left = [];
  const right = [];

  for (let i = 0; i < arr.length - 1; i++) {
    if (arr[i] < pivot) {
      left.push(arr[i]);
    } else {
      right.push(arr[i]);
    }
  }

  return [...quickSort(left), pivot, ...quickSort(right)];
}

// 示例用法
const unsortedArray = [5, 3, 7, 6, 2, 9];
const sortedArray = quickSort(unsortedArray);

console.log("未排序数组:", unsortedArray);
console.log("排序后数组:", sortedArray);
