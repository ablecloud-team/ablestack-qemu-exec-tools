// Copyright 2026 ABLECLOUD. Apache-2.0.
using System;
using System.IO;
using System.Diagnostics;
using System.Security.Principal;
public static class ProcessProfileFixture {
 static string Quote(string s){return "\""+s.Replace("\\","\\\\").Replace("\"","\\\"")+"\"";}
 public static int Main(string[] args) {
  if(args.Length!=1)return 2;
  if(File.Exists("fail-next-start"))return 7;
  File.WriteAllText(args[0],"{\"pid\":"+Process.GetCurrentProcess().Id+",\"account\":\""+WindowsIdentity.GetCurrent().User.Value+"\",\"session\":"+Process.GetCurrentProcess().SessionId+",\"cwd\":"+Quote(Environment.CurrentDirectory)+",\"environmentReferenceApplied\":"+(Environment.GetEnvironmentVariable("PROFILE_SECRET")!=null?"true":"false")+"}");
  while(true)System.Threading.Thread.Sleep(1000);
 }
}
