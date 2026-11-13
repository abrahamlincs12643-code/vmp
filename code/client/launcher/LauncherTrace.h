// Lightweight crash-proof tracing for the launcher. Writes <install>\launcher_trace.log (flushed on every line)
// so that a launcher that silently closes always leaves a trail of the last step it reached.
#pragma once

#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <wchar.h>

inline void LauncherTrace(const char* fmt, ...)
{
	static wchar_t path[MAX_PATH] = { 0 };

	if (!path[0])
	{
		wchar_t exe[MAX_PATH];
		GetModuleFileNameW(nullptr, exe, MAX_PATH);
		wchar_t* slash = wcsrchr(exe, L'\\');
		if (slash) { *(slash + 1) = L'\0'; }
		swprintf(path, MAX_PATH, L"%slauncher_trace.log", exe);
	}

	FILE* f = _wfopen(path, L"ab");
	if (!f)
	{
		return;
	}

	SYSTEMTIME st;
	GetLocalTime(&st);
	fprintf(f, "[%02d:%02d:%02d.%03d pid=%lu] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, GetCurrentProcessId());

	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);

	fputs("\r\n", f);
	fclose(f);
}

// logs fatal SEH exceptions (access violation, stack overflow, ...) and the process exit
inline LONG CALLBACK LauncherTraceVeh(PEXCEPTION_POINTERS ep)
{
	switch (ep->ExceptionRecord->ExceptionCode)
	{
		case EXCEPTION_ACCESS_VIOLATION:
		case EXCEPTION_STACK_OVERFLOW:
		case EXCEPTION_ILLEGAL_INSTRUCTION:
		case EXCEPTION_INT_DIVIDE_BY_ZERO:
		case EXCEPTION_IN_PAGE_ERROR:
		case 0xC0000409: // fast fail / stack cookie
		case 0xC0000374: // heap corruption
		case 0xC0000135: // dll not found
		case 0xC0000139: // entry point not found
			LauncherTrace("FATAL exception 0x%08X at %p", ep->ExceptionRecord->ExceptionCode, ep->ExceptionRecord->ExceptionAddress);
			break;
	}

	return EXCEPTION_CONTINUE_SEARCH;
}

inline void LauncherTraceInit()
{
	static bool done = false;
	if (done) { return; }
	done = true;

	AddVectoredExceptionHandler(1, LauncherTraceVeh);
	atexit([] { LauncherTrace("process exiting normally (atexit)"); });
	LauncherTrace("==== launcher start: %ls ====", GetCommandLineW());
}
