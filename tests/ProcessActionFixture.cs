// Copyright 2026 ABLECLOUD. Apache-2.0.
using System;using System.ServiceProcess;using System.Threading;
public class Fixture:ServiceBase {
 public Fixture(){ServiceName="AbleProcessQ5Fixture";CanStop=true;}
 protected override void OnStart(string[] args){} protected override void OnStop(){}
 public static void Main(string[] args){if(args.Length==1&&args[0]=="service")ServiceBase.Run(new Fixture());else{Console.WriteLine("ready");Thread.Sleep(Timeout.Infinite);}}
}
