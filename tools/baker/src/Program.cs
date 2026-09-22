using DBCD;
using DBCD.Providers;

namespace MapExtract;

/// Shortest Path Forever: headless, offline bakes from a local install.
///   NavBaker --region    <install> <product> <mapId> <outDir> <row0> <row1> <col0> <col1> [threads]
///   NavBaker --continent <install> <product> <mapId> <outDir> [threads]
///   NavBaker --maps      <install> <product>
/// row = tile.X (world X = north), col = tile.Y (world Y = west), inclusive ranges.
/// NAV_DBD names a directory holding Map.dbd and LiquidType.dbd (no GitHub fetch). CASC reads never fall back to
/// the CDN: CASC is read by Zezula's CascLib from local storage only, and a missing file aborts the bake.
public static class Program
{
    public static int Main(string[] args)
    {
        if (Dispatch(args)) return 0;
        Console.Error.WriteLine("usage: see header of Program.cs");
        return 2;
    }

    static bool Dispatch(string[] args)
    {
        if (args.Length == 0) return false;
        switch (args[0])
        {
            case "--region" when args.Length >= 9: RunRegion(args.Skip(1).ToArray()); return true;
            case "--continent" when args.Length >= 5: RunContinent(args.Skip(1).ToArray()); return true;
            case "--maps" when args.Length >= 3: RunMaps(args.Skip(1).ToArray()); return true;
            default: return false;
        }
    }

    sealed class Session
    {
        public required ZezulaCasc Casc;
        public required string Build;
        public required IDBCDStorage Maps;
        public required Extractor Ex;
    }

    static Session Open(string install, string product)
    {
        string build = BuildVersion(install, product);
        var casc = new ZezulaCasc(install, product);
        var dir = Environment.GetEnvironmentVariable("NAV_DBD");
        if (string.IsNullOrEmpty(dir) || !File.Exists(Path.Combine(dir, "Map.dbd")) || !File.Exists(Path.Combine(dir, "LiquidType.dbd")))
            throw new InvalidOperationException("NAV_DBD must name a directory with Map.dbd and LiquidType.dbd");
        var dbd = new FilesystemDBDProvider(dir);
        var maps = new DBCD.DBCD(new Db2(casc, 1349477), dbd).Load("Map", build);
        var liquid = new DBCD.DBCD(new Db2(casc, 1371380), dbd).Load("LiquidType", build);
        var bank = liquid.Values.ToDictionary(r => (ushort)r.ID, r => (LiquidClass)Convert.ToByte(r["SoundBank"]));
        var ex = new Extractor(casc, id => bank.TryGetValue(id, out var c) ? c : LiquidClass.Unknown);
        return new Session { Casc = casc, Build = build, Maps = maps, Ex = ex };
    }

    /// The build the DBDs are matched against: .build.info's Version for this product.
    static string BuildVersion(string install, string product)
    {
        var lines = File.ReadAllLines(Path.Combine(install, ".build.info"));
        var head = lines[0].Split('|').Select(h => h.Split('!')[0]).ToList();
        int iProduct = head.IndexOf("Product"), iVersion = head.IndexOf("Version");
        foreach (var line in lines.Skip(1))
        {
            var f = line.Split('|');
            if (f.Length > Math.Max(iProduct, iVersion) && f[iProduct] == product) return f[iVersion];
        }
        throw new InvalidOperationException($"product {product} not in .build.info");
    }

    static List<TileFiles> Tiles(Session s, int mapId, out string name)
    {
        var row = s.Maps[mapId];
        name = row["MapName_lang"]?.ToString() ?? "";
        using var w = s.Casc.OpenFile(Convert.ToInt32(row["WdtFileDataID"]));
        return Wdt.ReadTiles(w);
    }

    static void RunMaps(string[] a)
    {
        var s = Open(a[0], a[1]);
        foreach (var row in s.Maps.Values.OrderBy(r => r.ID))
        {
            int wdt = Convert.ToInt32(row["WdtFileDataID"]);
            string tiles = "0";
            try
            {
                if (wdt != 0 && s.Casc.FileExists(wdt))
                    using (var w = s.Casc.OpenFile(wdt)) tiles = Wdt.ReadTiles(w).Count.ToString();
            }
            catch (MissingFileException e) { tiles = "NOT-LOCAL(" + e.InnerException?.Message + ")"; }
            Console.WriteLine($"{row.ID}\t{row["Directory"]}\t{row["MapName_lang"]}\twdt={wdt}\ttiles={tiles}\t" +
                              $"instance={row["InstanceType"]}\tparent={row["ParentMapID"]}\tcosmetic={row["CosmeticParentMapID"]}");
        }
    }

    static void RunRegion(string[] a)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        string outDir = a[3];
        int mapId = int.Parse(a[2]);
        int r0 = int.Parse(a[4]), r1 = int.Parse(a[5]), c0 = int.Parse(a[6]), c1 = int.Parse(a[7]);
        int threads = a.Length > 8 ? int.Parse(a[8]) : Environment.ProcessorCount / 2;
        var s = Open(a[0], a[1]);
        var all = Tiles(s, mapId, out var name);
        Console.WriteLine($"{a[1]} {s.Build} map {mapId} \"{name}\" (opened in {sw.Elapsed.TotalSeconds:F1}s)");
        var byPos = all.ToDictionary(t => (t.X, t.Y));
        var soups = new Dictionary<(int, int), Extractor.Soup>();
        for (int x = r0 - 1; x <= r1 + 1; x++)
            for (int y = c0 - 1; y <= c1 + 1; y++)
                if (byPos.TryGetValue((x, y), out var t)) soups[(x, y)] = s.Ex.BuildTile(t);
        Console.WriteLine($"extracted {soups.Count} ADTs in {sw.Elapsed.TotalSeconds:F1}s");
        var targets = soups.Keys.Where(k => k.Item1 >= r0 && k.Item1 <= r1 && k.Item2 >= c0 && k.Item2 <= c1).ToList();
        var job = new BakeRun(outDir, mapId, resume: false);
        Parallel.ForEach(targets, new ParallelOptions { MaxDegreeOfParallelism = threads }, k => job.BakeOne(k, soups));
        job.Summary(sw);
    }

    /// Streams the continent a row of ADTs at a time: only rows x-1..x+1 are held while row x bakes. Resumable: a
    /// tile with a status file (ok / empty / FAILED) is skipped; delete status/ to rebake.
    static void RunContinent(string[] a)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        string outDir = a[3];
        int mapId = int.Parse(a[2]);
        int threads = a.Length > 4 ? int.Parse(a[4]) : Environment.ProcessorCount / 2;
        var s = Open(a[0], a[1]);
        var all = Tiles(s, mapId, out var name);
        var byPos = all.ToDictionary(t => (t.X, t.Y));
        var rows = all.Select(t => t.X).Distinct().OrderBy(x => x).ToList();
        if (Environment.GetEnvironmentVariable("ROWS") is { Length: > 0 } rr)
        {
            var lim = rr.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(int.Parse).ToArray();
            rows = rows.Where(x => x >= lim[0] && x <= lim[1]).ToList();
        }
        Console.WriteLine($"{a[1]} {s.Build} map {mapId} \"{name}\": {all.Count} ADTs in rows {rows.First()}-{rows.Last()} " +
                          $"(opened in {sw.Elapsed.TotalSeconds:F1}s)");
        var job = new BakeRun(outDir, mapId, resume: true);
        var soups = new Dictionary<(int, int), Extractor.Soup>();
        foreach (int x in rows)
        {
            var targets = all.Where(t => t.X == x && !job.Done(t.X, t.Y)).Select(t => (t.X, t.Y)).OrderBy(k => k.Item2).ToList();
            foreach (var k in soups.Keys.Where(k => k.Item1 < x - 1).ToList()) soups.Remove(k);
            if (targets.Count == 0) continue;
            var te = System.Diagnostics.Stopwatch.StartNew();
            int extracted = 0;
            foreach (var t in all.Where(t => t.X >= x - 1 && t.X <= x + 1).OrderBy(t => (t.X, t.Y)))
                if (!soups.ContainsKey((t.X, t.Y)) && targets.Any(k => Math.Abs(k.Item2 - t.Y) <= 1))
                {
                    soups[(t.X, t.Y)] = s.Ex.BuildTile(t);
                    extracted++;
                }
            Console.WriteLine($"row {x}: {targets.Count} to bake, extracted {extracted} ADTs in {te.Elapsed.TotalSeconds:F1}s, " +
                              $"holding {soups.Count}, models cached {s.Ex.CachedModels}, " +
                              $"rss {Environment.WorkingSet / 1048576} MB");
            Parallel.ForEach(targets, new ParallelOptions { MaxDegreeOfParallelism = threads }, k => job.BakeOne(k, soups));
            if (s.Ex.CachedModels > 20000) s.Ex.ClearCaches();
            GC.Collect();
        }
        job.Summary(sw);
    }

    sealed class BakeRun(string outDir, int mapId, bool resume)
    {
        readonly object _gate = new();
        bool _paramsWritten;
        int _ok, _empty, _failed, _retried;
        readonly string _status = Path.Combine(outDir, "status");

        string StatusPath(int x, int y) => Path.Combine(_status, $"{mapId:0000}_{x:00}_{y:00}");
        public bool Done(int x, int y) => resume && File.Exists(StatusPath(x, y));

        void Status(int x, int y, string line)
        {
            Directory.CreateDirectory(_status);
            var p = StatusPath(x, y);
            File.WriteAllText(p + ".tmp", line + "\n");
            File.Move(p + ".tmp", p, true);
            File.AppendAllText(Path.Combine(outDir, "tiles.log"), $"{x}_{y} {line}\n");
        }

        /// Tried in order after the default bake throws: other partitioners for contour failures, then coarser detail
        /// sampling, because Detour caps one polygon's detail mesh at 255 triangles. Only the detail heights change.
        static readonly (string, NavBake.Settings)[] Retries =
        [
            ("LAYERS", new NavBake.Settings { Partition = DotRecast.Recast.RcPartition.LAYERS }),
            ("MONOTONE", new NavBake.Settings { Partition = DotRecast.Recast.RcPartition.MONOTONE }),
            ("DETAILx2", new NavBake.Settings { DetailSampleDist = 12f, DetailSampleMaxError = 2f }),
            ("DETAILx4", new NavBake.Settings { DetailSampleDist = 24f, DetailSampleMaxError = 4f }),
        ];

        /// Every bake holds this for reading; an out-of-memory rebake takes it for writing, so it runs alone.
        static readonly ReaderWriterLockSlim Exclusive = new();
        static bool OutOfMemory(NavBake.Result r) => r.FailedTiles > 0 && (r.FailMessage + r.Message).Contains("OutOfMemoryException");

        /// Running out of memory says nothing about the tile: it is baked again alone with the same settings, so the
        /// output never depends on what the other threads held at the time.
        static NavBake.Result BakeFitting((int, int) k, Extractor.Soup soup, NavBake.Settings settings, NavBake.Clip clip)
        {
            NavBake.Result r;
            Exclusive.EnterReadLock();
            try { r = NavBake.Bake(soup, settings, default, clip); }
            finally { Exclusive.ExitReadLock(); }
            for (int attempt = 0; attempt < 3 && OutOfMemory(r); attempt++)
            {
                Exclusive.EnterWriteLock();
                try
                {
                    Console.WriteLine($"  [{k.Item1},{k.Item2}] out of memory; baking again alone");
                    GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
                    r = NavBake.Bake(soup, settings, default, clip);
                }
                finally { Exclusive.ExitWriteLock(); }
            }
            if (OutOfMemory(r)) throw new OutOfMemoryException($"tile {k.Item1}_{k.Item2} does not fit in memory even alone");
            return r;
        }

        public void BakeOne((int, int) k, Dictionary<(int, int), Extractor.Soup> soups)
        {
            var clip = NavBake.Clip.ForAdt(k.Item1, k.Item2);
            const float band = 8f;
            var soup = new Extractor.Soup();
            for (int dx = -1; dx <= 1; dx++)
                for (int dy = -1; dy <= 1; dy++)
                {
                    if (!soups.TryGetValue((k.Item1 + dx, k.Item2 + dy), out var s)) continue;
                    if (dx == 0 && dy == 0) soup.Append(s);
                    else soup.AppendClipped(s, clip.MinX - band, clip.MinY - band, clip.MaxX + band, clip.MaxY + band);
                }
            var settings = new NavBake.Settings();
            var t0 = System.Diagnostics.Stopwatch.StartNew();
            var r = BakeFitting(k, soup, settings, clip);
            string retry = "", first = r.FailedTiles > 0 ? r.FailMessage.Length > 0 ? r.FailMessage : r.Message : "";
            foreach (var (label, s) in Retries)
            {
                if (r.FailedTiles == 0) break;  // only a Recast exception is worth another try; "no geometry" is final
                Console.WriteLine($"  [{k.Item1},{k.Item2}] {(retry.Length == 0 ? "watershed" : retry)} failed ({r.Message}); retrying with {label}");
                r = BakeFitting(k, soup, s, clip);
                retry = label;
            }
            lock (_gate)
            {
                if (!r.Ok)
                {
                    bool failed = r.FailedTiles > 0;
                    if (failed) _failed++; else _empty++;
                    Console.WriteLine($"  [{k.Item1},{k.Item2}] {(failed ? "FAILED" : "empty:")} {r.Message}");
                    Status(k.Item1, k.Item2, $"{(failed ? "FAILED" : "empty")} {r.Message}");
                    return;
                }
                if (!_paramsWritten) { NavWriter.WriteMapParams(outDir, mapId, r.MeshParams); _paramsWritten = true; }
                long b = 0;
                foreach (var nt in r.Tiles) b += NavWriter.WriteTile(outDir, mapId, nt);
                _ok++;
                if (retry.Length > 0) _retried++;
                Console.WriteLine($"  [{k.Item1,2},{k.Item2,2}] {soup.TriCount + soup.LiquidTris,9:N0} tris -> {r.Tiles.Count} tiles, " +
                                  $"{r.PolyCount,7:N0} polys, maxverts {r.MaxMeshVerts:N0}, {t0.Elapsed.TotalSeconds,5:F1}s, {b / 1024.0,6:F0} KB" +
                                  string.Concat(r.Tiles.Select(t => $" {t.Row}_{t.Col}")) + (retry.Length > 0 ? $" (retry {retry})" : ""));
                Status(k.Item1, k.Item2, $"ok polys={r.PolyCount} tiles={r.Tiles.Count} secs={t0.Elapsed.TotalSeconds:F1}" +
                                         (retry.Length > 0 ? $" retry={retry} first=\"{first.Replace('\n', ' ')}\"" : ""));
            }
        }

        public void Summary(System.Diagnostics.Stopwatch sw) =>
            Console.WriteLine($"done in {sw.Elapsed.TotalSeconds:F1}s -> {outDir}: ok {_ok} (retried {_retried}), " +
                              $"empty {_empty}, FAILED {_failed}");
    }

    sealed class Db2(IFileSource casc, int fdid) : IDBCProvider
    {
        public Stream StreamForTableName(string tableName, string build) => casc.OpenFile(fdid);
    }
}
