#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
import importlib.util,unittest
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'lib/v2k/guest-config/prepare-networkmanager.py'
spec=importlib.util.spec_from_file_location('network_preparer',p);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class PrepareNetworkTest(unittest.TestCase):
 def setUp(self):
  self.text='# Created by cloud-init automatically, do not edit.\nAUTOCONNECT_PRIORITY=120\nBOOTPROTO=dhcp\nDEVICE=eth0\nDHCPV6C=yes\nHWADDR=50:6b:8d:df:c5:d2\nIPV6INIT=yes\nONBOOT=yes\nTYPE=Ethernet\nUSERCTL=no\n'
 def test_only_competing_cloud_init_profile_autoconnect_is_disabled(self):
  out=module.retired_ifcfg(self.text,'50:6b:8d:df:c5:d2','eth0');self.assertEqual(out,self.text.replace('ONBOOT=yes','ONBOOT=no'))
 def test_other_device_is_never_changed(self):
  with self.assertRaises(ValueError):module.retired_ifcfg(self.text,'50:6b:8d:df:c5:d2','eth1')
 def test_other_mac_is_never_changed(self):
  with self.assertRaises(ValueError):module.retired_ifcfg(self.text,'52:54:00:00:00:01','eth0')
 def test_non_cloud_init_configuration_requires_review(self):
  with self.assertRaises(ValueError):module.retired_ifcfg(self.text.replace('# Created by cloud-init automatically, do not edit.',''),'50:6b:8d:df:c5:d2','eth0')
 def test_custom_or_authenticated_profile_is_never_rewritten(self):
  with self.assertRaises(ValueError):module.retired_ifcfg(self.text+'PASSWORD=example\n','50:6b:8d:df:c5:d2','eth0')
 def test_repeat_preparation_is_idempotent(self):
  out=module.retired_ifcfg(self.text,'50:6b:8d:df:c5:d2','eth0');self.assertEqual(module.retired_ifcfg(out,'50:6b:8d:df:c5:d2','eth0'),out)
if __name__=='__main__':unittest.main()
