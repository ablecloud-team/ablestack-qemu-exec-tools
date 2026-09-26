// Copyright 2026 ABLECLOUD. Apache-2.0.
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class AbleProcessIdentity {
public static string JsonString(string value) {
 var b=new StringBuilder("\"");
 foreach(char c in value) {
  switch(c) {
   case '"': b.Append("\\\""); break;
   case '\\': b.Append("\\\\"); break;
   case '\b': b.Append("\\b"); break;
   case '\f': b.Append("\\f"); break;
   case '\n': b.Append("\\n"); break;
   case '\r': b.Append("\\r"); break;
   case '\t': b.Append("\\t"); break;
   default: if(c<32) b.Append("\\u"+((int)c).ToString("x4")); else b.Append(c); break;
  }
 }
 return b.Append('"').ToString();
}
public static string CanonicalService(string account,bool canStart,bool canStop,string command,string[] requires) {
 Array.Sort(requires,StringComparer.Ordinal);
 var dependencies=new List<string>(); foreach(string value in requires) dependencies.Add(JsonString(value));
 return "{\"account\":"+JsonString(account)+",\"canStart\":"+(canStart?"true":"false")+",\"canStop\":"+(canStop?"true":"false")+",\"command\":"+JsonString(command)+",\"requires\":["+String.Join(",",dependencies)+"],\"wants\":[]}";
}
private static System.Threading.Timer watchdog;
public static void StartDeadline(int ms) { watchdog=new System.Threading.Timer(_=>Environment.Exit(3),null,Math.Max(1,ms),System.Threading.Timeout.Infinite); }
public static void StopDeadline() { if(watchdog!=null) watchdog.Dispose(); }
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr h,out long creation,out long exit,out long kernel,out long user);
 [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h,out uint code);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int cls,IntPtr info,int length,out int needed);
 public sealed class Observation { public string Start; public string Owner; }
 public static Observation Read(uint pid) {
  IntPtr h=OpenProcess(0x1000,false,pid); if(h==IntPtr.Zero) return null;
  try {
   long creation,exit,kernel,user; uint code;
   if(!GetProcessTimes(h,out creation,out exit,out kernel,out user)||!GetExitCodeProcess(h,out code)||code!=259) return null;
   var result=new Observation { Start=creation.ToString(System.Globalization.CultureInfo.InvariantCulture) };
   IntPtr token;
   if(OpenProcessToken(h,8,out token)) {
    try { int needed; GetTokenInformation(token,1,IntPtr.Zero,0,out needed);
     if(needed>0 && needed<=65536) { IntPtr buffer=Marshal.AllocHGlobal(needed);
      try { if(GetTokenInformation(token,1,buffer,needed,out needed)) result.Owner=new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value; }
      finally { Marshal.FreeHGlobal(buffer); }
     }
    } finally { CloseHandle(token); }
   }
   return result;
  } finally { CloseHandle(h); }
 }
}
