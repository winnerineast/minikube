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

package machine

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	"k8s.io/minikube/pkg/minikube/bootstrapper"
	"k8s.io/minikube/pkg/minikube/constants"
	"k8s.io/minikube/pkg/minikube/registry"
	"k8s.io/minikube/pkg/minikube/sshutil"
	"k8s.io/minikube/pkg/provision"

	"github.com/docker/machine/libmachine"
	"github.com/docker/machine/libmachine/auth"
	"github.com/docker/machine/libmachine/cert"
	"github.com/docker/machine/libmachine/check"
	"github.com/docker/machine/libmachine/drivers"
	"github.com/docker/machine/libmachine/drivers/plugin"
	"github.com/docker/machine/libmachine/drivers/plugin/localbinary"
	"github.com/docker/machine/libmachine/engine"
	"github.com/docker/machine/libmachine/host"
	"github.com/docker/machine/libmachine/mcnutils"
	"github.com/docker/machine/libmachine/persist"
	"github.com/docker/machine/libmachine/ssh"
	"github.com/docker/machine/libmachine/state"
	"github.com/docker/machine/libmachine/swarm"
	"github.com/docker/machine/libmachine/version"
	"github.com/golang/glog"
	"github.com/pkg/errors"
)

func NewRPCClient(storePath, certsDir string) libmachine.API {
	c := libmachine.NewClient(storePath, certsDir)
	c.SSHClientType = ssh.Native
	return c
}

// NewAPIClient gets a new client.
func NewAPIClient() (libmachine.API, error) {
	storePath := constants.GetMinipath()
	certsDir := constants.MakeMiniPath("certs")

	return &LocalClient{
		certsDir:     certsDir,
		storePath:    storePath,
		Filestore:    persist.NewFilestore(storePath, certsDir, certsDir),
		legacyClient: NewRPCClient(storePath, certsDir),
	}, nil
}

// LocalClient is a non-RPC implementation
// of the libmachine API
type LocalClient struct {
	certsDir  string
	storePath string
	*persist.Filestore
	legacyClient libmachine.API
}

func (api *LocalClient) NewHost(driverName string, rawDriver []byte) (*host.Host, error) {
	var def registry.DriverDef
	var err error
	if def, err = registry.Driver(driverName); err != nil {
		return nil, err
	} else if !def.Builtin || def.DriverCreator == nil {
		return api.legacyClient.NewHost(driverName, rawDriver)
	}

	driver := def.DriverCreator()

	err = json.Unmarshal(rawDriver, driver)
	if err != nil {
		return nil, errors.Wrapf(err, "Error getting driver %s", string(rawDriver))
	}

	return &host.Host{
		ConfigVersion: version.ConfigVersion,
		Name:          driver.GetMachineName(),
		Driver:        driver,
		DriverName:    driver.DriverName(),
		HostOptions: &host.Options{
			AuthOptions: &auth.Options{
				CertDir:          api.certsDir,
				CaCertPath:       filepath.Join(api.certsDir, "ca.pem"),
				CaPrivateKeyPath: filepath.Join(api.certsDir, "ca-key.pem"),
				ClientCertPath:   filepath.Join(api.certsDir, "cert.pem"),
				ClientKeyPath:    filepath.Join(api.certsDir, "key.pem"),
				ServerCertPath:   filepath.Join(api.GetMachinesDir(), "server.pem"),
				ServerKeyPath:    filepath.Join(api.GetMachinesDir(), "server-key.pem"),
			},
			EngineOptions: &engine.Options{
				StorageDriver: "aufs",
				TLSVerify:     true,
			},
			SwarmOptions: &swarm.Options{},
		},
	}, nil
}

func (api *LocalClient) Load(name string) (*host.Host, error) {
	h, err := api.Filestore.Load(name)
	if err != nil {
		return nil, errors.Wrap(err, "Error loading host from store")
	}

	var def registry.DriverDef
	if def, err = registry.Driver(h.DriverName); err != nil {
		return nil, err
	} else if !def.Builtin || def.DriverCreator == nil {
		return api.legacyClient.Load(name)
	}

	h.Driver = def.DriverCreator()
	return h, json.Unmarshal(h.RawDriver, h.Driver)
}

func (api *LocalClient) Close() error {
	if api.legacyClient != nil {
		return api.legacyClient.Close()
	}
	return nil
}

func GetCommandRunner(h *host.Host) (bootstrapper.CommandRunner, error) {
	if h.DriverName != constants.DriverNone {
		client, err := sshutil.NewSSHClient(h.Driver)
		if err != nil {
			return nil, errors.Wrap(err, "getting ssh client for bootstrapper")
		}
		return bootstrapper.NewSSHRunner(client), nil
	}

	return &bootstrapper.ExecRunner{}, nil
}

func (api *LocalClient) Create(h *host.Host) error {
	if def, err := registry.Driver(h.DriverName); err != nil {
		return err
	} else if !def.Builtin || def.DriverCreator == nil {
		return api.legacyClient.Create(h)
	}

	steps := []struct {
		name string
		f    func() error
	}{
		{
			"Bootstrapping certs.",
			func() error { return cert.BootstrapCertificates(h.AuthOptions()) },
		},
		{
			"Running precreate checks.",
			h.Driver.PreCreateCheck,
		},
		{
			"Saving driver.",
			func() error {
				return api.Save(h)
			},
		},
		{
			"Creating VM.",
			h.Driver.Create,
		},
		{
			"Waiting for VM to start.",
			func() error {
				if h.Driver.DriverName() == "none" {
					return nil
				}
				return mcnutils.WaitFor(drivers.MachineInState(h.Driver, state.Running))
			},
		},
		{
			"Provisioning VM.",
			func() error {
				if h.Driver.DriverName() == "none" {
					return nil
				}
				pv := provision.NewBuildrootProvisioner(h.Driver)
				return pv.Provision(*h.HostOptions.SwarmOptions, *h.HostOptions.AuthOptions, *h.HostOptions.EngineOptions)
			},
		},
	}

	for _, step := range steps {
		if err := step.f(); err != nil {
			return errors.Wrap(err, fmt.Sprintf("Error executing step: %s\n", step.name))
		}
	}

	return nil
}

func StartDriver() {
	cert.SetCertGenerator(&CertGenerator{})
	check.DefaultConnChecker = &ConnChecker{}
	if os.Getenv(localbinary.PluginEnvKey) == localbinary.PluginEnvVal {
		registerDriver(os.Getenv(localbinary.PluginEnvDriverName))
	}

	localbinary.CurrentBinaryIsDockerMachine = true
}

type ConnChecker struct {
}

func (cc *ConnChecker) Check(h *host.Host, swarm bool) (string, *auth.Options, error) {
	authOptions := h.AuthOptions()
	dockerHost, err := h.Driver.GetURL()
	if err != nil {
		return "", &auth.Options{}, err
	}
	return dockerHost, authOptions, nil
}

// CertGenerator is used to override the default machine CertGenerator with a longer timeout.
type CertGenerator struct {
	cert.X509CertGenerator
}

// ValidateCertificate is a reimplementation of the default generator with a longer timeout.
func (cg *CertGenerator) ValidateCertificate(addr string, authOptions *auth.Options) (bool, error) {
	tlsConfig, err := cg.ReadTLSConfig(addr, authOptions)
	if err != nil {
		return false, err
	}

	dialer := &net.Dialer{
		Timeout: time.Second * 40,
	}

	_, err = tls.DialWithDialer(dialer, "tcp", addr, tlsConfig)
	if err != nil {
		return false, err
	}

	return true, nil
}

func registerDriver(driverName string) {
	def, err := registry.Driver(driverName)
	if err != nil {
		glog.Exitf("Unsupported driver: %s\n", driverName)
	}

	plugin.RegisterDriver(def.DriverCreator())
}
