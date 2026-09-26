// Copyright 2026 ABLECLOUD. Apache-2.0.
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class AbleProcessIdentity {
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
