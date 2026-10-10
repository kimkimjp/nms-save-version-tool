// No Man's Sky save version changer - core engine.
// C# port of reference/nms_downgrade.js (C# 5 / .NET Framework 4.x, compiled via PowerShell Add-Type).
//
// Format notes:
//   save*.hg    = LZ4 blocks with 16-byte header (magic 0xFEEDA1E5). Decompressed JSON starts with {"F2P":<ver>,
//                 where F2P = BaseVersion + GameMode*512.
//   mf_save*.hg = XXTEA-encrypted meta (432 bytes). u32[15]=disk size, u32[17]=BaseVersion, u32[18]=GameMode.
// The change rewrites the F2P digits inside the leading LZ4 literal run (same digit count, so sizes stay the same)
// and BaseVersion in the meta, then verifies by decoding before anything is written.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace NmsSaveTool
{
    public class SaveResult
    {
        public string Name { get; set; }
        public int? Slot { get; set; }
        public int? Mode { get; set; }
        public int? Base { get; set; }
        public int? F2P { get; set; }
        public int? Target { get; set; }
        public DateTime? MTime { get; set; }   // local time of the save file
        public string Action { get; set; }     // scan / same / would-change / changed / error
        public string Error { get; set; }
    }

    public static class NmsSave
    {
        private class NmsException : Exception
        {
            public NmsException(string message) : base(message) { }
        }

        private const uint SaveMagic = 0xFEEDA1E5u;
        private const uint MetaMagic = 0xEEEEEEBEu;
        private const int MetaLen = 0x1B0;            // 432 bytes: the only verified meta layout
        private const uint DL = 0x9E3779B9u;
        private const uint MaxChunkLen = 0x4000000u;  // sanity cap for a decompressed chunk (real data: 0x80000)

        private static readonly Regex SaveNameRe = new Regex("^save[0-9]*\\.hg$");
        private static readonly uint[] KEY = MakeBaseKey();

        private static string _lang = "en";

        /// <summary>"ja" or "en" (anything else becomes "en"). Used for error messages.</summary>
        public static string Lang
        {
            get { return _lang; }
            set { _lang = (value != null && value.Trim().ToLowerInvariant() == "ja") ? "ja" : "en"; }
        }

        private static string M(string ja, string en, params object[] args)
        {
            string s = (_lang == "ja") ? ja : en;
            if (args == null || args.Length == 0) return s;
            return string.Format(CultureInfo.InvariantCulture, s, args);
        }

        // ---------- byte helpers ----------
        private static uint ReadU32(byte[] b, int o)
        {
            return (uint)b[o] | ((uint)b[o + 1] << 8) | ((uint)b[o + 2] << 16) | ((uint)b[o + 3] << 24);
        }

        private static void WriteU32(byte[] b, int o, uint v)
        {
            b[o] = (byte)(v & 0xFF);
            b[o + 1] = (byte)((v >> 8) & 0xFF);
            b[o + 2] = (byte)((v >> 16) & 0xFF);
            b[o + 3] = (byte)((v >> 24) & 0xFF);
        }

        private static bool BytesEqual(byte[] a, byte[] b)
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }

        private static int IndexOf(byte[] hay, byte[] needle)
        {
            int last = hay.Length - needle.Length;
            for (int i = 0; i <= last; i++)
            {
                int j = 0;
                while (j < needle.Length && hay[i + j] == needle[j]) j++;
                if (j == needle.Length) return i;
            }
            return -1;
        }

        // ---------- LZ4 ----------
        private static byte[] Lz4Dec(byte[] src, int srcOff, int srcLen, int outLen)
        {
            byte[] outb = new byte[outLen];
            int i = srcOff, end = srcOff + srcLen, o = 0;
            while (i < end)
            {
                int t = src[i++];
                long l = t >> 4;
                if (l == 15)
                {
                    int b;
                    do
                    {
                        if (i >= end) throw new NmsException(M("LZ4 データが壊れています", "LZ4 data is corrupted"));
                        b = src[i++];
                        l += b;
                    } while (b == 255);
                }
                if (l > end - i || l > outLen - o) throw new NmsException(M("LZ4 データが壊れています", "LZ4 data is corrupted"));
                Buffer.BlockCopy(src, i, outb, o, (int)l);
                i += (int)l;
                o += (int)l;
                if (i >= end) break;
                if (i + 2 > end) throw new NmsException(M("LZ4 データが壊れています", "LZ4 data is corrupted"));
                int off = src[i] | (src[i + 1] << 8);
                i += 2;
                long m = t & 15;
                if (m == 15)
                {
                    int b;
                    do
                    {
                        if (i >= end) throw new NmsException(M("LZ4 データが壊れています", "LZ4 data is corrupted"));
                        b = src[i++];
                        m += b;
                    } while (b == 255);
                }
                m += 4;
                if (off == 0 || off > o || m > outLen - o) throw new NmsException(M("LZ4 データが壊れています", "LZ4 data is corrupted"));
                for (int k = 0; k < m; k++, o++) outb[o] = outb[o - off];
            }
            if (o == outLen) return outb;
            byte[] trimmed = new byte[o];
            Buffer.BlockCopy(outb, 0, trimmed, 0, o);
            return trimmed;
        }

        private static byte[] Decode(byte[] buf)
        {
            MemoryStream ms = new MemoryStream();
            int p = 0;
            while (p < buf.Length)
            {
                if (p + 16 > buf.Length || ReadU32(buf, p) != SaveMagic)
                    throw new NmsException(M("セーブ形式が想定外です（オフセット {0}）", "Unexpected save format (offset {0})", p));
                uint cs = ReadU32(buf, p + 4);
                uint ds = ReadU32(buf, p + 8);
                p += 16;
                if (cs > (uint)(buf.Length - p) || ds > MaxChunkLen)
                    throw new NmsException(M("LZ4 データが壊れています", "LZ4 data is corrupted"));
                byte[] part = Lz4Dec(buf, p, (int)cs, (int)ds);
                ms.Write(part, 0, part.Length);
                p += (int)cs;
            }
            return ms.ToArray();
        }

        // ---------- XXTEA ----------
        private static uint[] MakeBaseKey()
        {
            byte[] kb = Encoding.ASCII.GetBytes("NAESEVADNAYRTNRG");
            uint[] k = new uint[4];
            for (int i = 0; i < 4; i++) k[i] = ReadU32(kb, i * 4);
            return k;
        }

        private static uint Rotl(uint x, int r)
        {
            return (x << r) | (x >> (32 - r));
        }

        private static uint[] SlotKey(int s)
        {
            uint[] k = (uint[])KEY.Clone();
            unchecked
            {
                uint t = Rotl((uint)s ^ 0x1422CB8Cu, 13);
                k[0] = t * 5u + 0xE6546B64u;
            }
            return k;
        }

        private static uint Mx(uint z, uint y, uint sum, int p, int e, uint[] k)
        {
            unchecked
            {
                return (((z >> 5) ^ (y << 2)) + ((y >> 3) ^ (z << 4))) ^ ((sum ^ y) + (k[(p & 3) ^ e] ^ z));
            }
        }

        private static uint[] ToV(byte[] b)
        {
            if (b.Length == 0 || b.Length % 4 != 0)
                throw new NmsException(M("メタファイルのサイズが想定外です", "Unexpected meta file size"));
            uint[] v = new uint[b.Length / 4];
            for (int i = 0; i < v.Length; i++) v[i] = ReadU32(b, i * 4);
            return v;
        }

        private static byte[] ToB(uint[] v)
        {
            byte[] o = new byte[v.Length * 4];
            for (int i = 0; i < v.Length; i++) WriteU32(o, i * 4, v[i]);
            return o;
        }

        private static byte[] Dec(byte[] b, int s)
        {
            uint[] v = ToV(b);
            uint[] k = SlotKey(s);
            int n = v.Length;
            int r = (b.Length == 0x68) ? 8 : 6;
            uint sum = unchecked((uint)r * DL);
            uint y = v[0];
            uint z;
            for (int q = 0; q < r; q++)
            {
                int e = (int)((sum >> 2) & 3);
                for (int p = n - 1; p > 0; p--)
                {
                    z = v[p - 1];
                    y = v[p] = unchecked(v[p] - Mx(z, y, sum, p, e, k));
                }
                z = v[n - 1];
                y = v[0] = unchecked(v[0] - Mx(z, y, sum, 0, e, k));
                sum = unchecked(sum - DL);
            }
            return ToB(v);
        }

        private static byte[] Enc(byte[] b, int s)
        {
            uint[] v = ToV(b);
            uint[] k = SlotKey(s);
            int n = v.Length;
            int r = (b.Length == 0x68) ? 8 : 6;
            uint sum = 0;
            uint z = v[n - 1];
            uint y;
            while (r-- > 0)
            {
                sum = unchecked(sum + DL);
                int e = (int)((sum >> 2) & 3);
                int p;
                for (p = 0; p < n - 1; p++)
                {
                    y = v[p + 1];
                    z = v[p] = unchecked(v[p] + Mx(z, y, sum, p, e, k));
                }
                y = v[0];
                z = v[n - 1] = unchecked(v[n - 1] + Mx(z, y, sum, p, e, k));
            }
            return ToB(v);
        }

        /// <summary>Encrypts a plain meta block with the given slot key (used by tests).</summary>
        public static byte[] EncryptMeta(byte[] plain, int slot)
        {
            return Enc(plain, slot);
        }

        private static int FindSlot(byte[] b, out byte[] plain)
        {
            if (b.Length % 4 != 0 || b.Length < 0x68)
                throw new NmsException(M("メタファイルのサイズが想定外です", "Unexpected meta file size"));
            for (int s = 0; s < 64; s++)
            {
                byte[] d = Dec(b, s);
                if (ReadU32(d, 0) == MetaMagic)
                {
                    plain = d;
                    return s;
                }
            }
            throw new NmsException(M("メタファイルを復号できません", "Cannot decrypt the meta file"));
        }

        // ---------- file writing ----------
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileEx(string existing, string newName, int flags);

        // Same semantics as Node's fs.renameSync on Windows (MOVEFILE_REPLACE_EXISTING), plus write-through.
        private static void MoveOver(string from, string to)
        {
            if (!MoveFileEx(from, to, 0x1 | 0x8))
                throw new IOException(new Win32Exception(Marshal.GetLastWin32Error()).Message);
        }

        private static void TryDelete(string path)
        {
            try { File.Delete(path); } catch { }
        }

        // Write save + meta as a pair: both temp files first, then rename. If the meta rename fails,
        // put the original save back so the two never disagree.
        private static void WritePair(string sf, byte[] s2, byte[] sOrig, string mf, byte[] m2)
        {
            string st = sf + ".tmp", mt = mf + ".tmp";
            try
            {
                File.WriteAllBytes(st, s2);
                File.WriteAllBytes(mt, m2);
            }
            catch
            {
                TryDelete(st);
                TryDelete(mt);
                throw;
            }
            try
            {
                MoveOver(st, sf);
            }
            catch
            {
                TryDelete(st);
                TryDelete(mt);
                throw;
            }
            try
            {
                MoveOver(mt, mf);
            }
            catch
            {
                TryDelete(mt);
                // Restore the save through a temp file too, so a crash here never leaves a truncated save.
                try { File.WriteAllBytes(st, sOrig); MoveOver(st, sf); }
                catch { TryDelete(st); File.WriteAllBytes(sf, sOrig); }
                throw;
            }
        }

        // ---------- F2P ----------
        private static bool ParseF2P(byte[] raw, out int f2p)
        {
            f2p = 0;
            int n = Math.Min(32, raw.Length);
            char[] c = new char[n];
            for (int i = 0; i < n; i++) c[i] = (char)raw[i];
            Match mm = Regex.Match(new string(c), "^\\{\"F2P\":([0-9]+),");
            if (!mm.Success) return false;
            return int.TryParse(mm.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out f2p);
        }

        // ---------- public API ----------

        /// <summary>Inspect one save and (optionally) rewrite it. Never throws; errors go into SaveResult.Error.</summary>
        public static SaveResult Process(string dir, string name, int? target, bool write)
        {
            SaveResult r = new SaveResult();
            r.Name = name;
            r.Target = target;
            try
            {
                if (target.HasValue && (target.Value < 1000 || target.Value > 9999))
                    throw new NmsException(M("目標バージョンは4桁の整数で指定してください", "Target version must be a 4-digit integer"));

                string sf = Path.Combine(dir, name + ".hg");
                string mf = Path.Combine(dir, "mf_" + name + ".hg");
                if (!File.Exists(mf))
                    throw new NmsException(M("mf_" + name + ".hg がありません", "mf_" + name + ".hg not found"));
                if (!File.Exists(sf))
                    throw new NmsException(M(name + ".hg がありません", name + ".hg not found"));
                r.MTime = File.GetLastWriteTime(sf);
                byte[] s = File.ReadAllBytes(sf);
                byte[] m = File.ReadAllBytes(mf);

                if (m.Length != MetaLen)
                    throw new NmsException(M("未対応のセーブ形式（メタ長 {0}）", "Unsupported save format (meta length {0})", m.Length));

                byte[] md;
                int slot = FindSlot(m, out md);
                r.Slot = slot;
                if (!BytesEqual(Enc(md, slot), m))
                    throw new NmsException(M("メタの再暗号化が一致しません", "Meta re-encryption does not match"));

                uint baseU = ReadU32(md, 68);
                uint modeU = ReadU32(md, 72);
                if (baseU > (uint)int.MaxValue || modeU > (uint)int.MaxValue)
                    throw new NmsException(M("メタの値が範囲外です", "Meta values are out of range"));
                int baseV = (int)baseU;
                int modeV = (int)modeU;
                r.Base = baseV;
                r.Mode = modeV;

                if (ReadU32(md, 60) != (uint)s.Length)
                    throw new NmsException(M("メタのファイルサイズ記録が一致しません", "File size recorded in the meta does not match"));

                byte[] raw = Decode(s);
                int f2p;
                if (!ParseF2P(raw, out f2p))
                    throw new NmsException(M("バージョン(F2P)が見つかりません", "Version (F2P) not found"));
                r.F2P = f2p;
                if ((long)f2p - baseV != (long)modeV * 512)
                    throw new NmsException(M("F2P {0} がベース {1}・モード {2} と整合しません",
                        "F2P {0} is inconsistent with base {1} and mode {2}", f2p, baseV, modeV));

                if (!target.HasValue) { r.Action = "scan"; return r; }
                int tgt = target.Value;
                if (baseV == tgt) { r.Action = "same"; return r; }

                long newF2P = (long)tgt + (long)modeV * 512;
                string oldS = "\"F2P\":" + f2p.ToString(CultureInfo.InvariantCulture) + ",";
                string newS = "\"F2P\":" + newF2P.ToString(CultureInfo.InvariantCulture) + ",";
                if (oldS.Length != newS.Length)
                    throw new NmsException(M("桁数が変わるバージョンには変更できません",
                        "Cannot change to a version with a different number of digits"));
                byte[] oldB = Encoding.ASCII.GetBytes(oldS);
                byte[] newB = Encoding.ASCII.GetBytes(newS);

                int ci = IndexOf(s, oldB);
                if (ci < 0 || ci > 200)
                    throw new NmsException(M("F2P が圧縮データ先頭にありません", "F2P was not found at the start of the compressed data"));
                byte[] s2 = (byte[])s.Clone();
                Buffer.BlockCopy(newB, 0, s2, ci, newB.Length);

                byte[] exp = (byte[])raw.Clone();
                int ri = IndexOf(raw, oldB);
                if (ri < 0)
                    throw new NmsException(M("書き換え後の検証に失敗しました", "Verification after rewrite failed"));
                Buffer.BlockCopy(newB, 0, exp, ri, newB.Length);
                if (!BytesEqual(Decode(s2), exp))
                    throw new NmsException(M("書き換え後の検証に失敗しました", "Verification after rewrite failed"));

                byte[] md2 = (byte[])md.Clone();
                WriteU32(md2, 68, (uint)tgt);
                byte[] m2 = Enc(md2, slot);
                if (ReadU32(Dec(m2, slot), 68) != (uint)tgt)
                    throw new NmsException(M("メタの検証に失敗しました", "Meta verification failed"));

                if (!write) { r.Action = "would-change"; return r; }

                WritePair(sf, s2, s, mf, m2);

                // Re-read from disk to prove what landed.
                byte[] chk;
                FindSlot(File.ReadAllBytes(mf), out chk);
                int back;
                bool okBack = ParseF2P(Decode(File.ReadAllBytes(sf)), out back);
                if (ReadU32(chk, 68) != (uint)tgt || !okBack || back != newF2P)
                    throw new NmsException(M("書き込み後の再読込で値が一致しません", "Values do not match after re-reading the written files"));
                r.Action = "changed";
            }
            catch (Exception e)
            {
                r.Error = e.Message;
                r.Action = "error";
            }
            return r;
        }

        private static int SaveNo(string name)
        {
            string d = name.Substring(4);
            if (d.Length == 0) return 1;
            int n;
            if (!int.TryParse(d, NumberStyles.None, CultureInfo.InvariantCulture, out n)) return int.MaxValue;
            return n == 0 ? 1 : n;
        }

        private static int CompareSaveNames(string a, string b)
        {
            int c = SaveNo(a).CompareTo(SaveNo(b));
            return c != 0 ? c : string.CompareOrdinal(a, b);
        }

        /// <summary>save.hg, save2.hg, ... (without ".hg") in numeric order. Throws if the folder does not exist.</summary>
        public static string[] ListSaves(string dir)
        {
            string[] files = Directory.GetFiles(dir);
            List<string> names = new List<string>();
            foreach (string f in files)
            {
                string fn = Path.GetFileName(f);
                if (SaveNameRe.IsMatch(fn)) names.Add(fn.Substring(0, fn.Length - 3));
            }
            names.Sort(CompareSaveNames);
            return names.ToArray();
        }
    }
}
