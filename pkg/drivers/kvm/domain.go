/*
Copyright 2016 The Kubernetes Authors All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package kvm

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"net"
	"text/template"

	libvirt "github.com/libvirt/libvirt-go"
	"github.com/pkg/errors"
)

const domainTmpl = `
<domain type='kvm'>
  <name>{{.MachineName}}</name> 
  <memory unit='MB'>{{.Memory}}</memory>
  <vcpu>{{.CPU}}</vcpu>
  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>
  <cpu mode='host-passthrough'/>
  <os>
    <type>hvm</type>
    <boot dev='cdrom'/>
    <boot dev='hd'/>
    <bootmenu enable='no'/>
  </os>
  <devices>
    <disk type='file' device='cdrom'>
      <source file='{{.ISO}}'/>
      <target dev='hdc' bus='scsi'/>
      <readonly/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw' cache='default' io='threads' />
      <source file='{{.DiskPath}}'/>
      <target dev='hda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='{{.Network}}'/>
      <mac address='{{.MAC}}'/>
      <model type='virtio'/>
    </interface>
    <interface type='network'>
      <source network='{{.PrivateNetwork}}'/>
      <mac address='{{.MAC}}'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <rng model='virtio'>
      <backend model='random'>/dev/random</backend>
    </rng>
    {{if .GPU}}
    {{.DevicesXML}}
    {{end}}
  </devices>
</domain>
`

const connectionErrorText = `
Error connecting to libvirt socket.  Have you set up libvirt correctly?

# Install libvirt and qemu-kvm on your system, e.g.
# Debian/Ubuntu (for older Debian/Ubuntu versions, you may have to use libvirt-bin instead of libvirt-clients and libvirt-daemon-system)
$ sudo apt install libvirt-clients libvirt-daemon-system qemu-kvm
# Fedora/CentOS/RHEL
$ sudo yum install libvirt-daemon-kvm qemu-kvm

# Add yourself to the libvirt group so you don't need to sudo
# NOTE: For older Debian/Ubuntu versions change the group to [libvirtd]
$ sudo usermod -a -G libvirt $(whoami)

# Update your current session for the group change to take effect
# NOTE: For older Debian/Ubuntu versions change the group to [libvirtd]
$ newgrp libvirt

Visit https://github.com/kubernetes/minikube/blob/master/docs/drivers.md#kvm-driver for more information.
`

func randomMAC() (net.HardwareAddr, error) {
	buf := make([]byte, 6)
	_, err := rand.Read(buf)
	if err != nil {
		return nil, err
	}
	// We unset the first and second least significant bits (LSB) of the MAC
	//
	// The LSB of the first octet
	// 0 for unicast
	// 1 for multicast
	//
	// The second LSB of the first octet
	// 0 for universally administered addresses
	// 1 for locally administered addresses
	buf[0] = buf[0] & 0xfc
	return buf, nil
}

func (d *Driver) getDomain() (*libvirt.Domain, *libvirt.Connect, error) {
	conn, err := getConnection()
	if err != nil {
		return nil, nil, errors.Wrap(err, "getting domain")
	}

	dom, err := conn.LookupDomainByName(d.MachineName)
	if err != nil {
		return nil, nil, errors.Wrap(err, "looking up domain")
	}

	return dom, conn, nil
}

func getConnection() (*libvirt.Connect, error) {
	conn, err := libvirt.NewConnect(qemusystem)
	if err != nil {
		return nil, errors.Wrap(err, connectionErrorText)
	}

	return conn, nil
}

func closeDomain(dom *libvirt.Domain, conn *libvirt.Connect) error {
	dom.Free()
	if res, _ := conn.Close(); res != 0 {
		return fmt.Errorf("Error closing connection CloseConnection() == %d, expected 0", res)
	}
	return nil
}

func (d *Driver) createDomain() (*libvirt.Domain, error) {
	tmpl := template.Must(template.New("domain").Parse(domainTmpl))
	var domainXml bytes.Buffer
	if err := tmpl.Execute(&domainXml, d); err != nil {
		return nil, errors.Wrap(err, "executing domain xml")
	}

	conn, err := getConnection()
	if err != nil {
		return nil, errors.Wrap(err, "Error getting libvirt connection")
	}
	defer conn.Close()

	dom, err := conn.DomainDefineXML(domainXml.String())
	if err != nil {
		return nil, errors.Wrapf(err, "Error defining domain xml: %s", domainXml.String())
	}

	return dom, nil
}
