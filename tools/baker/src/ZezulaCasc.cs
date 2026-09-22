using System.Runtime.InteropServices;

namespace MapExtract;

/// Local CASC storage through Ladislav Zezula's CascLib (MIT), P/Invoke into libcasc. Local storage only: CascLib's
/// CDN code is never called, so a file the install does not hold fails the bake.
public sealed class ZezulaCasc : IFileSource, IDisposable
{
    const string Lib = "casc";
    const uint CASC_OPEN_BY_FILEID = 3, CASC_STRICT_DATA_CHECK = 0x10, CASC_OVERCOME_ENCRYPTED = 0x20, CASC_LOCALE_ENUS = 2;
    const int ERROR_FILE_NOT_FOUND = 2;  // ENOENT on Linux
    const int ERROR_FILE_ENCRYPTED = 1005;

    [DllImport(Lib)] static extern bool CascOpenStorage(string szParams, uint dwLocaleMask, out IntPtr phStorage);
    [DllImport(Lib)] static extern bool CascCloseStorage(IntPtr hStorage);
    [DllImport(Lib)] static extern bool CascOpenFile(IntPtr hStorage, IntPtr pvFileName, uint dwLocaleFlags, uint dwOpenFlags, out IntPtr phFile);
    [DllImport(Lib)] static extern bool CascGetFileSize64(IntPtr hFile, out ulong size);
    [DllImport(Lib)] static extern unsafe bool CascReadFile(IntPtr hFile, byte* buffer, uint toRead, out uint read);
    [DllImport(Lib)] static extern bool CascCloseFile(IntPtr hFile);
    [DllImport(Lib)] static extern uint GetCascError();

    readonly IntPtr _storage;

    public ZezulaCasc(string install, string product)
    {
        if (!CascOpenStorage($"{install}*{product}", CASC_LOCALE_ENUS, out _storage))
            throw new IOException($"CascOpenStorage({install}*{product}) failed: error {GetCascError()}");
    }

    public bool FileExists(int fileDataId)
    {
        if (CascOpenFile(_storage, (IntPtr)fileDataId, CASC_LOCALE_ENUS, CASC_OPEN_BY_FILEID, out var h)) { CascCloseFile(h); return true; }
        uint err = GetCascError();
        if (err == ERROR_FILE_NOT_FOUND) return false;
        throw new MissingFileException(fileDataId, new IOException($"CascOpenFile error {err}"));
    }

    /// A block encrypted with a key the client has not been given (unreleased content, e.g. DB2 hotfix sections) is
    /// read as zeros, as WoW-Tools' CascLib does, but never silently: each such file is logged by FileDataID.
    public Stream OpenFile(int fileDataId)
    {
        if (TryRead(fileDataId, CASC_STRICT_DATA_CHECK, out var data, out uint err)) return data;
        if (err != ERROR_FILE_ENCRYPTED || !TryRead(fileDataId, CASC_STRICT_DATA_CHECK | CASC_OVERCOME_ENCRYPTED, out data, out err))
            throw new MissingFileException(fileDataId, new IOException($"CascLib error {err}"));
        Console.Error.WriteLine($"casc: file {fileDataId} has blocks encrypted with an unknown key; read them as zeros");
        return data;
    }

    unsafe bool TryRead(int fileDataId, uint flags, out Stream data, out uint err)
    {
        data = Stream.Null;
        err = 0;
        if (!CascOpenFile(_storage, (IntPtr)fileDataId, CASC_LOCALE_ENUS, CASC_OPEN_BY_FILEID | flags, out var h)) { err = GetCascError(); return false; }
        try
        {
            if (!CascGetFileSize64(h, out ulong size)) { err = GetCascError(); return false; }
            var buf = new byte[size];
            uint read = 0;
            fixed (byte* p = buf)
                if (size > 0 && (!CascReadFile(h, p, (uint)size, out read) || read != size)) { err = GetCascError(); return false; }
            data = new MemoryStream(buf, writable: false);
            return true;
        }
        finally { CascCloseFile(h); }
    }

    public void Dispose() => CascCloseStorage(_storage);
}
