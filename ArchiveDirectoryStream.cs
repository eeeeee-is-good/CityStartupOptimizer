using System;
using System.Diagnostics;
using System.IO;

namespace CityStartupOptimizer
{
    internal sealed class ArchiveDirectoryStream : Stream
    {
        readonly Stream source;
        readonly BufferedStream directory;
        // SharpZipLib reads the fixed portion of each ZIP local header one byte at a time.
        readonly byte[] header = new byte[30];
        int next, count;
        Stream reader;
        internal readonly long Start = Stopwatch.GetTimestamp();

        internal ArchiveDirectoryStream(Stream source)
        {
            this.source = source;
            reader = directory = new BufferedStream(source, 64 * 1024);
        }

        internal void FinishDirectory()
        {
            directory.Flush();
            reader = source;
        }

        void DiscardLookahead()
        {
            if (next < count) source.Seek(next - count, SeekOrigin.Current);
            next = count = 0;
        }

        public override bool CanRead { get { return reader.CanRead; } }
        public override bool CanSeek { get { return reader.CanSeek; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return reader.Length; } }
        public override long Position
        {
            get { return reader.Position - (count - next); }
            set { DiscardLookahead(); reader.Position = value; }
        }
        public override long Seek(long offset, SeekOrigin origin)
        {
            DiscardLookahead();
            return reader.Seek(offset, origin);
        }
        public override int Read(byte[] buffer, int offset, int size)
        {
            DiscardLookahead();
            return reader.Read(buffer, offset, size);
        }
        public override int ReadByte()
        {
            if (reader == directory) return directory.ReadByte();
            if (next == count)
            {
                count = source.Read(header, 0, header.Length);
                next = 0;
                if (count == 0) return -1;
            }
            return header[next++];
        }
        public override void Flush()
        {
            DiscardLookahead();
            reader.Flush();
        }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int size) { throw new NotSupportedException(); }
        protected override void Dispose(bool disposing)
        {
            next = count = 0;
            if (disposing) directory.Dispose();
            base.Dispose(disposing);
        }
    }
}
