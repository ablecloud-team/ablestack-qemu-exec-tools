// Copyright 2026 ABLECLOUD. Apache-2.0.
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Web.Script.Serialization;
public static class AbleProcessAction {
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr h,out long c,out long e,out long k,out long u);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr h,uint code);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessCritical(IntPtr h,out bool critical);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr h,uint flags,StringBuilder name,ref uint size);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint milliseconds);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool MoveFileEx(string from,string to,uint flags);
 public sealed class Target:IDisposable {
  IntPtr handle;
  public Target(uint pid,string ticks) {
   if(pid<=4 || pid==(uint)System.Diagnostics.Process.GetCurrentProcess().Id) throw new InvalidOperationException("PROTECTED_TARGET");
   handle=OpenProcess(0x100001|0x1000,false,pid);
   if(handle==IntPtr.Zero) throw new InvalidOperationException("STALE_IDENTITY");
   try {
    long c,e,k,u;bool critical;uint size=32768;var image=new StringBuilder((int)size);
    if(!GetProcessTimes(handle,out c,out e,out k,out u)||c.ToString(System.Globalization.CultureInfo.InvariantCulture)!=ticks||WaitForSingleObject(handle,0)!=258)throw new InvalidOperationException("STALE_IDENTITY");
    if(!IsProcessCritical(handle,out critical)||critical||!QueryFullProcessImageName(handle,0,image,ref size))throw new InvalidOperationException("PROTECTED_TARGET");
    string name=Path.GetFileName(image.ToString()).ToLowerInvariant();
    if(new HashSet<string>{"qemu-ga.exe","smss.exe","csrss.exe","wininit.exe","winlogon.exe","services.exe","lsass.exe","svchost.exe","registry","system","secure system","powershell.exe","pwsh.exe"}.Contains(name))throw new InvalidOperationException("PROTECTED_TARGET");
   }catch{Dispose();throw;}
  }
  public void Kill(){if(WaitForSingleObject(handle,0)!=258)throw new InvalidOperationException("STALE_IDENTITY");if(!TerminateProcess(handle,1))throw new InvalidOperationException("EXEC_FAILED");}
  public bool Exited(int milliseconds){return WaitForSingleObject(handle,(uint)Math.Max(0,milliseconds))==0;}
  public void Dispose(){if(handle!=IntPtr.Zero){CloseHandle(handle);handle=IntPtr.Zero;}}
 }
 public static Dictionary<string,object> Parse(string json){var serializer=new JavaScriptSerializer();serializer.MaxJsonLength=16777216;serializer.RecursionLimit=24;return (Dictionary<string,object>)serializer.DeserializeObject(json);}
 public static void SecureDirectory(string path) {
  if(!Directory.Exists(path)) {
   var acl=new DirectorySecurity();acl.SetAccessRuleProtection(true,false);
   foreach(string sid in new[]{"S-1-5-18","S-1-5-32-544"})acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid),FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
   Directory.CreateDirectory(path,acl);
  }
  CheckPath(path,true);
 }
 public static void CheckPath(string path,bool directory) {
  if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)throw new IOException("Reparse point denied");
  FileSystemSecurity acl=directory?(FileSystemSecurity)Directory.GetAccessControl(path):(FileSystemSecurity)File.GetAccessControl(path);
  foreach(FileSystemAccessRule rule in acl.GetAccessRules(true,true,typeof(SecurityIdentifier))) {
   string sid=rule.IdentityReference.Value;
   if(rule.AccessControlType==AccessControlType.Allow && sid!="S-1-5-18" && sid!="S-1-5-32-544" && (rule.FileSystemRights&(FileSystemRights.Write|FileSystemRights.Modify|FileSystemRights.FullControl))!=0)throw new IOException("Unsafe journal ACL");
  }
 }
 public static void Save(string path,string json) {
  if(Encoding.UTF8.GetByteCount(json)>16777216)throw new IOException("Journal limit");
  if(File.Exists(path))CheckPath(path,false);
  string temp=path+"."+Guid.NewGuid().ToString()+".tmp";
  try {
   using(var stream=new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough)) {byte[] data=new UTF8Encoding(false,true).GetBytes(json);stream.Write(data,0,data.Length);stream.Flush(true);}
   if(!MoveFileEx(temp,path,1|8))throw new IOException("Atomic journal write failed");
  } finally {if(File.Exists(temp))File.Delete(temp);}
 }
 // Validate syntax and reject duplicate keys before PowerShell creates case-insensitive objects.
 public static void ValidateJson(string json){if(Encoding.UTF8.GetByteCount(json)>65536)throw new FormatException("Request limit");var parser=new Strict(json);parser.Value(0);parser.Space();if(parser.Pos!=json.Length)throw new FormatException("Trailing data");}
 sealed class Strict {
  string s;public int Pos;public Strict(string value){s=value;}
  public void Space(){while(Pos<s.Length&&" \r\n\t".IndexOf(s[Pos])>=0)Pos++;}
  string String(){int start=Pos++;bool escape=false;while(Pos<s.Length){char c=s[Pos++];if(c=='"'&&!escape)return new JavaScriptSerializer().Deserialize<string>(s.Substring(start,Pos-start));if(c<32)throw new FormatException("Control");if(c=='\\'&&!escape)escape=true;else escape=false;}throw new FormatException("String");}
  public void Value(int depth){if(depth>12)throw new FormatException("Depth");Space();if(Pos>=s.Length)throw new FormatException("EOF");char c=s[Pos];
   if(c=='{'){Pos++;Space();var keys=new HashSet<string>(StringComparer.OrdinalIgnoreCase);if(Pos<s.Length&&s[Pos]=='}'){Pos++;return;}while(true){Space();if(Pos>=s.Length||s[Pos]!='"'||!keys.Add(String()))throw new FormatException("Key");Space();if(Pos>=s.Length||s[Pos++]!=':')throw new FormatException("Colon");Value(depth+1);Space();if(Pos>=s.Length)throw new FormatException("EOF");char end=s[Pos++];if(end=='}')return;if(end!=',')throw new FormatException("Comma");}}
   if(c=='['){Pos++;Space();if(Pos<s.Length&&s[Pos]==']'){Pos++;return;}while(true){Value(depth+1);Space();if(Pos>=s.Length)throw new FormatException("EOF");char end=s[Pos++];if(end==']')return;if(end!=',')throw new FormatException("Comma");}}
   if(c=='"'){String();return;}int begin=Pos;while(Pos<s.Length&&",]} \r\n\t".IndexOf(s[Pos])<0)Pos++;string token=s.Substring(begin,Pos-begin);if(!System.Text.RegularExpressions.Regex.IsMatch(token,"^(true|false|null|-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?)$"))throw new FormatException("Token");
  }
 }
}
