/*
 * wmain_shim.c — Windows 交叉链接的入口垫片
 * ---------------------------------------------------------------------------
 * Odin 在 Windows 上发出的入口是 `wmain`（UTF-16 命令行），不是 `main`。
 * zig >= 0.17.1 的 mingw CRT 选择只看目标文件里有没有 `main`：只有 `wmain`
 * 时它会选窗口子系统的 crtexewin.obj（要求 `WinMain`），于是链接报
 *   undefined symbol: WinMain  (referenced by crtexewin.c)
 *
 * 这里补一个 `main`，用 CommandLineToArgvW 把命令行重建成 UTF-16 argv，
 * 再原样转给 Odin 的 `wmain`——既让 zig 选控制台 CRT（crtexe），又保住了
 * Odin 对 Unicode 参数的处理。
 *
 * 刻意不 include <windows.h>：本文件要能在没有 Windows SDK 的机器上用
 * `zig cc -target x86_64-windows-gnu` 编译，手写声明即可。
 */
typedef unsigned short xchar;

extern xchar **CommandLineToArgvW(const xchar *lpCmdLine, int *pNumArgs);
extern xchar *GetCommandLineW(void);
extern void *LocalFree(void *hMem);

int wmain(int argc, xchar **argv);

int main(void) {
	int argc = 0;
	xchar **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
	int rc = wmain(argc, argv);
	if (argv) {
		LocalFree((void *)argv);
	}
	return rc;
}
