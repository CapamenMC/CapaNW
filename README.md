# CapaNW native launcher

The Windows launcher is a .NET 8 WPF application for x64. It builds with the
.NET SDK, a C++ compiler (MSVC or MinGW-w64), and the pinned Obfuscar tool
restored from `.config/dotnet-tools.json`.

## Build and package

From PowerShell in this directory:

```powershell
.\scripts\publish-csharp.ps1 -Version 1.0.11
```

The script compiles the native integrity DLL, publishes the self-contained WPF
application, obfuscates its private .NET API while preserving WPF/XAML
identifiers, runs native and XAML smoke tests, builds a per-user Windows
installer, and writes a SHA-256 sidecar. Outputs are placed in a timestamped
`artifacts\capanw-*` directory.

To test an installer and its uninstaller locally:

```powershell
.\scripts\test-installer.ps1 -InstallerPath .\artifacts\capanw-<version>-<timestamp>\CapaNW-Setup-1.0.11.exe
```

The updater reads the static `update-manifest.json` file from the repository's
`main` branch instead of calling the GitHub Releases API. The publish script
generates this manifest for the selected version. Upload the matching
`CapaNW-Setup-<version>.exe` and `.sha256` files to the GitHub Release first,
then publish the generated manifest at the repository root on `main`. The
manifest contains public GitHub download links; this removes the Releases API
request, but does not hide GitHub or the manifest URL from users.

## Native integrity component

`guard\capanw_integrity.cpp` is the native SHA-256 verifier called before the
launcher installs its bundled client mod. `guard\capanw_guard.cpp` is not used
by the C# build: its debugger/process scanning and forced-shutdown behavior
would interfere with ordinary developer and diagnostic tools.

The generated release is not code-signed. A valid publisher certificate is
required before distributing it as a trusted public Windows release.
