import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

void main() {
  // Initialize COM
  CoInitializeEx(COINIT_APARTMENTTHREADED);

  final progman = FindWindow(
    PCWSTR('Progman'.toNativeUtf16()),
    PCWSTR(nullptr),
  ).value;
  print('Progman HWND: ${(progman as Pointer).address.toRadixString(16)}');

  // Send 0x052C message to Progman
  final result = calloc<IntPtr>();
  SendMessageTimeout(
    progman,
    0x052C,
    WPARAM(0),
    LPARAM(0),
    SMTO_NORMAL,
    1000,
    result,
  );
  print('SendMessageTimeout sent.');

  int hwndAddress = 0;
  int index = 0;
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

    // Check if this window has SHELLDLL_DefView as a child
    final shellDllResult = FindWindowEx(
      hwnd,
      HWND(nullptr),
      PCWSTR('SHELLDLL_DefView'.toNativeUtf16()),
      PCWSTR(nullptr),
    );
    final shellDll = shellDllResult.value;
    final hasShell = (shellDll as Pointer).address != 0;

    final rect = calloc<RECT>();
    GetClientRect(hwnd, rect);
    final w = rect.ref.right - rect.ref.left;
    final h = rect.ref.bottom - rect.ref.top;
    calloc.free(rect);

    if (className == 'WorkerW' || className == 'Progman' || hasShell) {
      print(
        'Window #${index++}: HWND=${hwndAddress.toRadixString(16)}, Class=$className, Title="$title", Size=${w}x$h, HasSHELLDLL_DefView=$hasShell',
      );
      if (hasShell) {
        print(
          '  SHELLDLL_DefView HWND: ${(shellDll as Pointer).address.toRadixString(16)}',
        );
      }
    }
  }

  CoUninitialize();
}
