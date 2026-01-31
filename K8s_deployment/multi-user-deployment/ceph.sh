sudo snap install microceph --channel=latest/edge

sudo microceph cluster bootstrap

# Add Datadisk for cephfs, these steps will change in production cephfs.
for l in a b c; do
  loop_file="$(sudo mktemp -p /mnt XXXX.img)"
  sudo truncate -s 2G "${loop_file}"
  loop_dev="$(sudo losetup --show -f "${loop_file}")"
  # the block-devices plug doesn't allow accessing /dev/loopX
  # devices so we make those same devices available under alternate
  # names (/dev/sdiY)
  minor="${loop_dev##/dev/loop}"
  sudo mknod -m 0660 "/dev/sdi${l}" b 7 "${minor}"
  sudo microceph disk add --wipe "/dev/sdi${l}"
done

sudo microceph.ceph config set global osd_pool_default_size 2                               
sudo microceph.ceph config set mgr mgr_standby_modules false                                                                                                                                                      
sudo microceph.ceph config set osd osd_crush_chooseleaf_type 0

# Add cephfs shared file system
sudo microceph.ceph osd pool create cephfs_meta
sudo microceph.ceph osd pool create cephfs_data

sudo ceph fs new newFs cephfs_meta cephfs_data

# Verify ceph status
sudo microceph.ceph status

# Verify number disk attached to ceph
sudo microceph disk list

# Verify shared file system properly setup
sudo ceph fs ls

