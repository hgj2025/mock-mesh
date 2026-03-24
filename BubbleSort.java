public class BubbleSort {
    public static void bubbleSort(int[] arr) {
        int n = arr.length;
        for (int i = 0; i < n - 1; i++) {
            for (int j = 0; j < n - i - 1; j++) {
                if (arr[j] > arr[j + 1]) {
                    int temp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = temp;
                }
            }
        }
    }

    public static void printArray(int[] arr) {
        for (int num : arr) {
            System.out.print(num + " ");
        }
        System.out.println();
    }

    public static void main(String[] args) {
        int[] unsortedArray = {5, 3, 7, 6, 2, 9};
        System.out.print("未排序数组: ");
        printArray(unsortedArray);

        bubbleSort(unsortedArray);

        System.out.print("排序后数组: ");
        printArray(unsortedArray);
    }
}
