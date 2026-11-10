using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CapaNW.Launcher;

internal sealed class UpdateService
{
    private const long MaximumInstallerBytes = 800L * 1024 * 1024;
    private const string ReleasePathPrefix = "/CapamenMC/CapaNW/releases/download/v";
    private static readonly HttpClient Http = CreateHttpClient();
    private static readonly Uri UpdateManifestUri = new(
        "https://raw.githubusercontent.com/CapamenMC/CapaNW/main/update-manifest.json");

    public async Task<LauncherUpdate?> GetAvailableUpdateAsync(
        Version currentVersion,
        CancellationToken cancellationToken = default)
    {
        using var response = await Http.GetAsync(UpdateManifestUri, cancellationToken);
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(
            await response.Content.ReadAsStreamAsync(cancellationToken));
        var root = document.RootElement;
        var versionText = ReadString(root, "version");
        if (!Version.TryParse(versionText, out var latestVersion) ||
            latestVersion <= currentVersion)
        {
            return null;
        }

        var installerName = $"CapaNW-Setup-{latestVersion}.exe";
        var installerUrl = ReadAssetUrl(root, "installerUrl", latestVersion, installerName);
        var checksumUrl = ReadAssetUrl(
            root,
            "checksumUrl",
            latestVersion,
            installerName + ".sha256");
        return new LauncherUpdate(latestVersion, installerUrl, checksumUrl);
    }

    public async Task<string> DownloadAndVerifyAsync(
        LauncherUpdate update,
        Action<int> reportProgress,
        CancellationToken cancellationToken = default)
    {
        var expectedHash = await ReadExpectedHashAsync(update.ChecksumUrl, cancellationToken);
        var updateDirectory = Path.Combine(LauncherPaths.UserDataDirectory, "updates");
        Directory.CreateDirectory(updateDirectory);
        var installerPath = Path.Combine(updateDirectory, $"CapaNW-Setup-{update.Version}.exe");
        var temporaryPath = installerPath + "." + Guid.NewGuid().ToString("N") + ".download";
        try
        {
            using var response = await Http.GetAsync(
                update.InstallerUrl,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is > MaximumInstallerBytes)
            {
                throw new InvalidDataException("Güncelleme dosyası boyut sınırını aşıyor.");
            }

            await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
            await using var target = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                81920,
                useAsync: true);
            using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[81920];
            long totalBytes = 0;
            var contentLength = response.Content.Headers.ContentLength;
            while (true)
            {
                var count = await source.ReadAsync(buffer, cancellationToken);
                if (count == 0)
                {
                    break;
                }
                totalBytes += count;
                if (totalBytes > MaximumInstallerBytes)
                {
                    throw new InvalidDataException("Güncelleme dosyası boyut sınırını aşıyor.");
                }
                hasher.AppendData(buffer, 0, count);
                await target.WriteAsync(buffer.AsMemory(0, count), cancellationToken);
                if (contentLength is > 0)
                {
                    reportProgress((int)Math.Min(100, totalBytes * 100 / contentLength.Value));
                }
            }
            await target.FlushAsync(cancellationToken);

            if (totalBytes == 0 ||
                contentLength is > 0 && totalBytes != contentLength.Value ||
                !string.Equals(
                    Convert.ToHexString(hasher.GetHashAndReset()),
                    expectedHash,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Güncelleme SHA-256 doğrulaması başarısız oldu.");
            }

            File.Move(temporaryPath, installerPath, overwrite: true);
            reportProgress(100);
            return installerPath;
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static async Task<string> ReadExpectedHashAsync(
        Uri checksumUri,
        CancellationToken cancellationToken)
    {
        using var response = await Http.GetAsync(checksumUri, cancellationToken);
        response.EnsureSuccessStatusCode();
        var checksumText = await response.Content.ReadAsStringAsync(cancellationToken);
        var match = Regex.Match(checksumText, @"\A\s*([0-9a-fA-F]{64})(?:\s+.*)?\s*\z");
        if (!match.Success)
        {
            throw new InvalidDataException("Güncelleme SHA-256 dosyası geçersiz.");
        }
        return match.Groups[1].Value;
    }

    private static Uri ReadAssetUrl(
        JsonElement manifest,
        string propertyName,
        Version version,
        string assetName)
    {
        var url = ReadString(manifest, propertyName);
        var expectedPath = $"{ReleasePathPrefix}{version}/{assetName}";
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            uri.Scheme != Uri.UriSchemeHttps ||
            !string.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"Güncelleme dosyası bulunamadı: {assetName}");
        }

        if (!string.Equals(uri.AbsolutePath, expectedPath, StringComparison.Ordinal) ||
            uri.Query.Length != 0 ||
            uri.Fragment.Length != 0)
        {
            throw new InvalidDataException($"Güncelleme bağlantısı geçersiz: {assetName}");
        }

        return uri;
    }

    private static string ReadString(JsonElement element, string propertyName)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(propertyName, out var value) &&
               value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? string.Empty
            : string.Empty;
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient();
        client.DefaultRequestHeaders.UserAgent.Add(
            new ProductInfoHeaderValue("CapaNW", "1.0"));
        client.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));
        return client;
    }
}

internal sealed record LauncherUpdate(Version Version, Uri InstallerUrl, Uri ChecksumUrl);
