import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

void main() {
  int hwndAddress = 0;
  int index = 0;
  print('Starting window enumeration...');
  while (true) {
    final hwndResult = FindWindowEx(
      HWND(nullptr),
      HWND(Pointer.fromAddress(hwndAddress)),
      PCWSTR(nullptr),
      PCWSTR(nullptr),
    );
    final hwnd = hwndResult.value;
    if ((hwnd as Pointer).address == 0) break;
    hwndAddress = (hwnd as Pointer).address;

    final classNamePtr = calloc<Uint16>(256).cast<Utf16>();
    GetClassName(hwnd, PWSTR(classNamePtr), 256);
    final className = classNamePtr.toDartString();
    calloc.free(classNamePtr);

    final titlePtr = calloc<Uint16>(256).cast<Utf16>();
    GetWindowText(hwnd, PWSTR(titlePtr), 256);
    final title = titlePtr.toDartString();
    calloc.free(titlePtr);

    if (className.contains('WorkerW') || className.contains('Progman') || className.contains('Shell')) {
      print('Window #$index: HWND=${hwndAddress.toRadixString(16)}, Class=$className, Title="$title"');
    }
    index++;
  }
  print('Done. Total windows checked: $index');
}
