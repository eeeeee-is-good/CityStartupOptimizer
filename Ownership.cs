using System;
using System.Collections.Generic;
using Colossal;
using Colossal.IO.AssetDatabase;
using Entry = Colossal.IO.AssetDatabase.FileSystemDataSource.EntryInfo;

namespace CityStartupOptimizer
{
    // Per application of the playset. The authoritative entry for each changed ID
    // is read back from the game after the pack's population task completes.
    public static class Ownership
    {
        sealed class Index
        {
            internal object Owner;
            internal IReadOnlyDictionary<Hash128,Entry> Entries;
            internal bool Rebuild = true;
            internal readonly HashSet<Hash128> Changed = new HashSet<Hash128>();
            internal readonly HashSet<Entry> Seen = new HashSet<Entry>();
            internal readonly Dictionary<string, HashSet<Hash128>> Paths = new Dictionary<string, HashSet<Hash128>>(StringComparer.Ordinal);
            internal readonly Dictionary<Hash128,string> Previous = new Dictionary<Hash128,string>();
            internal void Remember(Hash128 id, Entry entry)
            {
                string path=entry.path;
                string old;
                if(Previous.TryGetValue(id,out old) && !String.Equals(old,path,StringComparison.Ordinal))
                {
                    var bucket=Paths[old];
                    bucket.Remove(id);
                    if(bucket.Count==0) Paths.Remove(old);
                }
                HashSet<Hash128> ids;
                if(!Paths.TryGetValue(path,out ids)) Paths[path]=ids=new HashSet<Hash128>();
                ids.Add(id); Previous[id]=path; Seen.Add(entry);
            }
        }
        static readonly object gate = new object();
        static volatile Index current;
        static int depth;
        public static void Begin()
        {
            lock(gate){ depth++; current = depth==1 ? new Index() : null; }
        }
        public static void End()
        {
            lock(gate){ if(depth>0) depth--; current=null; }
        }
        public static void Changed(object source,Hash128 id)
        {
            var ix=current;
            if(ix!=null && ReferenceEquals(ix.Owner,source)) lock(gate) ix.Changed.Add(id);
        }
        public static void Reset(object source)
        {
            var ix=current;
            if(ix!=null && ReferenceEquals(ix.Owner,source)) lock(gate) ix.Rebuild=true;
        }
        public static void Moved(Entry entry)
        {
            var ix=current;
            if(ix!=null && entry.path!=null) lock(gate) if(ix.Seen.Contains(entry)) ix.Rebuild=true;
        }
        public static IEnumerable<KeyValuePair<Hash128,Entry>> Candidates(IReadOnlyDictionary<Hash128,Entry> entries,object owner,string prefix)
        {
            lock(gate)
            {
                var ix=current;
                if(ix==null || Loading.ActiveWriters!=0) return entries;
                long revision=Loading.WriteRevision;
                if(!ReferenceEquals(ix.Entries,entries) || ix.Rebuild)
                {
                    ix=current=new Index{Owner=owner,Entries=entries,Rebuild=false};
                    foreach(var e in entries) ix.Remember(e.Key,e.Value);
                }
                else
                {
                    foreach(var key in ix.Changed)
                    {
                        Entry value;
                        if(entries.TryGetValue(key,out value)) ix.Remember(key,value);
                        else { ix.Rebuild=true; return entries; }
                    }
                }
                ix.Changed.Clear();
                var result=new List<KeyValuePair<Hash128,Entry>>();
                foreach(var group in ix.Paths)
                {
                    if(!group.Key.StartsWith(prefix)) continue;
                    foreach(var id in group.Value)
                    {
                        Entry e;
                        if(entries.TryGetValue(id,out e)) result.Add(new KeyValuePair<Hash128,Entry>(id,e));
                    }
                }
                if(Loading.ActiveWriters!=0 || Loading.WriteRevision!=revision){ix.Rebuild=true;return entries;}
                return result;
            }
        }
    }
}
