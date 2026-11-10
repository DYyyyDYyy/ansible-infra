# -*- mode: ruby -*-
# Four empty VMs on libvirt/KVM. Vagrant only creates them and brings up the
# private network; everything else is done by Ansible from this machine
# (`make up` = `vagrant up` + playbooks/site.yml against inventories/vagrant).
#
# Boxes can be overridden, e.g. DEBIAN_BOX=generic/debian13 make up

# The rockylinux/10 entry on Vagrant Cloud points at a 10.0 image that the
# Rocky mirror no longer has (404 as of 2026-11), so the Rocky box comes
# straight from the official mirror, pinned by its published SHA256.
# Its metadata also claims a 5 GB disk while the image is 10 GiB; vagrant-libvirt
# trusts the metadata, the root partition ends past the disk and boot hangs in
# the initramfs. disk_gb below overrides it.
ROCKY_MIRROR_BOX = {
  name: "rockylinux-10.2-20260525",
  disk_gb: 10,
  url: "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/" \
       "Rocky-10-Vagrant-Libvirt-10.2-20260525.0.x86_64.vagrant.libvirt.box",
  sha256: "a45a4725eaac11518691fdc64a84a42c04da6e3f4b73219088fe83bded849181",
}.freeze

BOXES = {
  debian: { name: ENV.fetch("DEBIAN_BOX", "debian/trixie64") },
  rocky: ENV.key?("ROCKY_BOX") ? { name: ENV["ROCKY_BOX"] } : ROCKY_MIRROR_BOX,
}.freeze

# Vagrant configures Red Hat guest networks with ifcfg files, which EL10 no
# longer reads (NetworkManager keyfiles only): the VM boots, `vagrant up`
# succeeds, and the private NIC simply has no address. So on Rocky the
# private address is set with nmcli; the NIC is found by its fixed MAC.
ROCKY_PRIVATE_NIC = <<~'SH'
  set -eu
  ip="$1" mac="$2"
  dev=$(ip -o link | awk -v mac="$mac" 'index(tolower($0), mac) { sub(":$", "", $2); print $2; exit }')
  [ -n "$dev" ] || { echo "no NIC with MAC $mac" >&2; exit 1; }
  if ! nmcli -t -f NAME connection show | grep -qx private; then
    nmcli connection add type ethernet ifname "$dev" con-name private \
      ipv4.method manual ipv4.addresses "$ip/24" ipv6.method disabled
  fi
  nmcli connection up private >/dev/null
SH

# Keep in sync with inventories/vagrant/hosts.yml
NODES = [
  { name: "lb",   box: :rocky,  ip: "10.10.10.10", memory: 768 },
  { name: "app1", box: :debian, ip: "10.10.10.11", memory: 1024 },
  { name: "app2", box: :rocky,  ip: "10.10.10.12", memory: 1024 },
  { name: "db",   box: :debian, ip: "10.10.10.13", memory: 1024 },
].freeze

Vagrant.configure("2") do |config|
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider :libvirt do |lv|
    lv.cpus = 1
    # Rocky Linux 10 requires an x86-64-v3 CPU; libvirt's default model is
    # older and the kernel refuses to boot on it.
    lv.cpu_mode = "host-passthrough"
  end

  NODES.each do |node|
    config.vm.define node[:name] do |machine|
      box = BOXES.fetch(node[:box])
      machine.vm.box = box[:name]
      if box[:url]
        machine.vm.box_url = box[:url]
        machine.vm.box_download_checksum_type = "sha256"
        machine.vm.box_download_checksum = box[:sha256]
      end
      machine.vm.hostname = node[:name]
      # NIC 1 is Vagrant's management network (NAT, internet access);
      # NIC 2 is the private network the hosts talk to each other on.
      rocky = node[:box] == :rocky
      mac = format("52:54:00:10:10:%02x", node[:ip].split(".").last.to_i)
      machine.vm.network :private_network,
                         ip: node[:ip],
                         mac: mac,
                         auto_config: !rocky,
                         libvirt__network_name: "ansible-infra",
                         libvirt__dhcp_enabled: false
      if rocky
        machine.vm.provision "private-nic", type: "shell", run: "always",
                                            inline: ROCKY_PRIVATE_NIC, args: [node[:ip], mac]
      end
      machine.vm.provider :libvirt do |lv|
        lv.memory = node[:memory]
        lv.machine_virtual_size = box[:disk_gb] if box[:disk_gb]
      end
    end
  end
end
