#!/bin/bash

# Copyright 2014:
# Simon Lopez <simon.lopez@slopez.org>
#
# Use of this source code is governed under the Apache License, Version 2.0
# http://www.apache.org/licenses/LICENSE-2.0
#

##########
# CONFIG #
##########
# sd image size
SDIMG_MB="2048"
# image file
SDIMG_FILE="$HOME/hiwr.sdimg"
# build directory
BUILD_DIR="$HOME/hiwr-build"
# DISTRO
DISTRO=wheezy

#########
# BUILD #
#########
show_time() {
  E=$(($2 - $1))
  h=$(($E/3600))
  m=$((($E%3600)/60))
  s=$(($E%60))
  printf "%02d:%02d:%02d\n" $h $m $s
}

ARCH=`dpkg --print-architecture`

if [ ! -e $BUILD_DIR ]
then
  echo === Building ===
  START=`date +"%s"`
  mkdir $BUILD_DIR
  cd $BUILD_DIR
  case $ARCH in
    armhf)
      echo "armhf, no cross compile needed"
      apt-get install -y gcc-4.7
      ;;
    *)
      echo "$ARCH crosscompile needed"
      # add emdebian repositories
      grep "emdebian" /etc/apt/sources.list > /dev/null 2> /dev/null
      if [ $? -ne 0 ]
      then
        echo "deb http://www.emdebian.org/debian wheezy main" >> /etc/apt/sources.list
        echo "deb http://www.emdebian.org/debian sid main" >> /etc/apt/sources.list
      fi
      # install needed packages
      apt-get update
      apt-get install -y emdebian-archive-keyring
      apt-get install -y gcc-4.7-arm-linux-gnueabihf
  esac
  apt-get install -y parted ncurses-dev uboot-mkimage build-essential git dosfstools kpartx qemu-user-static debootstrap binfmt-support qemu
  # a little hack
  rm /usr/bin/arm-linux-gnueabihf-gcc
  ln -s /usr/bin/arm-linux-gnueabihf-gcc-4.7 /usr/bin/arm-linux-gnueabihf-gcc
  echo === Building Uboot ===
  rm -Rf u-boot-sunxi
  git clone -b sunxi https://github.com/linux-sunxi/u-boot-sunxi.git
  cd u-boot-sunxi
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- A13-OLinuXino_config
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
  ls u-boot.bin u-boot-sunxi-with-spl.bin spl/sunxi-spl.bin
  echo === Building kernel ===
  cd $BUILD_DIR
  rm -Rf linux-sunxi
  git clone https://github.com/linux-sunxi/linux-sunxi
  cd linux-sunxi
  wget "https://gist.githubusercontent.com/simonlopez/51741b8a440b627b3394/raw/35c0ee3ebd82cba16e6fca70560e1a992e74bf3d/a13_olimex_kernel_config" -O ./arch/arm/configs/a13_linux_defconfig
  wget "https://gist.githubusercontent.com/simonlopez/51741b8a440b627b3394/raw/96cc2adee80d0e57ad85ded511d1992c0d335e4d/hiwr_kernel_config" -O hiwr-config
  # Adding missing config
  echo "# Hiwr specific lines" >> ./arch/arm/configs/a13_linux_defconfig
  echo "SUN4I_GPIO_UGLY=y" >> ./arch/arm/configs/a13_linux_defconfig
  while read line
  do
    grep $line a13_linux_defconfig > /dev/null 2> /dev/null
    if [ $? -ne 0 ]
    then
      echo $line >> ./arch/arm/configs/a13_linux_defconfig
    fi
  done < hiwr-config
  rm hiwr-config

  make ARCH=arm a13_linux_defconfig
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j4 uImage
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j4 INSTALL_MOD_PATH=out modules
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j4 INSTALL_MOD_PATH=out modules_install

  ls out/lib/modules/*/
  END=`date +"%s"`
  echo -n "Building duration: "
  show_time $START $END
fi

START=`date +"%s"`
cd $BUILD_DIR

if [ -e $SDIMG_FILE ]
then
  rm -f $SDIMG_FILE
fi

echo === Create empty file ===
dd if=/dev/zero of=$SDIMG_FILE bs=1M count=$SDIMG_MB > /dev/null 2>&1

echo === Create partitions ===
PARTITION_BOOT_OFFSET=2048
PARTITION_ROOT_OFFSET=34815
PARTITION_BOOT_OFFSET=2048
PARTITION_ROOT_OFFSET=34815

fdisk $SDIMG_FILE >/dev/null 2>&1 <<EOF
n
p
1
$PARTITION_BOOT_OFFSET
$PARTITION_ROOT_OFFSET
n
p
2


w
EOF

PARTITION_BOOT_OFFSET=`parted -s $SDIMG_FILE unit B print | tail -n3 | head -n1 | awk '{print $2}'`
PARTITION_ROOT_OFFSET=`parted -s $SDIMG_FILE unit B print | tail -n2 | head -n1 | awk '{print $2}'`

PARTITION_BOOT_OFFSET=${PARTITION_BOOT_OFFSET%B}
PARTITION_ROOT_OFFSET=${PARTITION_ROOT_OFFSET%B}

# in bytes
PARTITION_BOOT_SIZE=`parted -s $SDIMG_FILE unit B print | tail -n3 | head -n1 | awk '{print $4}'`
PARTITION_ROOT_SIZE=`parted -s $SDIMG_FILE unit B print | tail -n2 | head -n1 | awk '{print $4}'`

PARTITION_BOOT_SIZE=${PARTITION_BOOT_SIZE%B}
PARTITION_ROOT_SIZE=${PARTITION_ROOT_SIZE%B}

echo === Format partitions ===
kpartx -a $SDIMG_FILE

ERR=$?
while [ $? -ne 0 ]
do
  kpartx -dv /dev/loop0
  sleep 2
  kpartx -a $SDIMG_FILE
  ERR=$?
done
sleep 3

LOOP=`kpartx -l $SDIMG_FILE | head -1 | cut -d" " -f5 | cut -d"/" -f3`

PART1=`ls /dev/mapper/${LOOP}p1`
PART2=`ls /dev/mapper/${LOOP}p2`

mkfs.vfat $PART1 > /dev/null 2>&1
mkfs.ext3 $PART2 > /dev/null 2>&1

echo === Copy files ===

MOUNT=`mktemp -d`
dd if=u-boot-sunxi/u-boot-sunxi-with-spl.bin of=/dev/$LOOP bs=1024 seek=8
sync
mount $PART1 $MOUNT
cp linux-sunxi/arch/arm/boot/uImage $MOUNT
wget "https://www.dropbox.com/s/xcu1u4xygsps3el/script.bin" -O $MOUNT/script.bin
sync
umount $MOUNT

echo === Build pure Debian armhf rootfs ===
cd $BUILD_DIR
mount $PART2 $MOUNT

echo === debootstrap first phase ===
debootstrap --arch=armhf --foreign $DISTRO $MOUNT http://ftp.debian.org/debian

if [ $ARCH != "armhf" ]
then
  cp /usr/bin/qemu-arm-static $MOUNT/usr/bin/
fi

cp /etc/resolv.conf $MOUNT/etc

echo === debootstrap second phase ===
LC_ALL=C LANGUAGE=C LANG=C chroot $MOUNT /debootstrap/debootstrap --second-stage

echo === copy kernel modules and firmwares ===
if [ -e $MOUNT/lib/modules/ ]
then
  cp -rf linux-sunxi/out/lib/modules/* $MOUNT/lib/modules/
else
  mkdir $MOUNT/lib/modules/
  cp -rf linux-sunxi/out/lib/modules/* $MOUNT/lib/modules/
fi
if [ -e linux-sunxi/out/lib/firmware/ ]
then
  cp -rf linux-sunxi/out/lib/firmware/* $MOUNT/lib/firmware/
fi

echo === post debootstrap ===
cat <<EOT > $MOUNT/etc/apt/sources.list
deb http://ftp.debian.org/debian $DISTRO main contrib non-free
deb-src http://ftp.debian.org/debian $DISTRO main contrib non-free
deb http://ftp.debian.org/debian $DISTRO-updates main contrib non-free
deb-src http://ftp.debian.org/debian $DISTRO-updates main contrib non-free
deb http://ftp.debian.org/debian $DISTRO-backports main
deb-src http://ftp.debian.org/debian $DISTRO-backports main
deb http://security.debian.org/debian-security $DISTRO/updates main contrib non-free
deb-src http://security.debian.org/debian-security $DISTRO/updates main contrib non-free
EOT

cat <<EOT > $MOUNT/etc/apt/apt.conf.d/71-no-recommends
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOT

echo === mount devices ===
mnt_devices="proc dev dev/pts sys"
for i in $mnt_devices ; do
  mount -o bind /$i "$MOUNT"/$i
done

echo === finish configuration ===
cat <<EOT > $MOUNT/root/finish.sh
#!/bin/bash
echo "hiwr" > /etc/hostname
echo "mali" >> /etc/modules
echo "KERNEL=="mali", MODE="0660", GROUP="video"" > /etc/udev/rules.d/50-mali.rules
echo "KERNEL=="ump", MODE="0660", GROUP="video"" >> /etc/udev/rules.d/50-mali.rules
apt-get update
apt-get install -y locales dialog wget ca-certificates
cp /etc/locale.gen /etc/locale.gen.old
sed -i "s/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g" /etc/locale.gen
locale-gen --purge
echo -e 'LANG="en_US.UTF-8"\nLANGUAGE="en_US:en"\n' > /etc/default/locale
apt-get install -y openssh-server ntpdate wireless-tools wpasupplicant hostapd iw xserver-xorg libts-bin libts-dev libts-0.0-0 resolvconf 
echo "hiwr" > /etc/hostname
echo T0:2345:respawn:/sbin/getty -L ttyS0 115200 vt100 >> /etc/inittab
echo -e "hiwr\nhiwr" | passwd root
cat <<EOF > /etc/apt/sources.list.d/ros-latest.list
deb http://packages.namniart.com/repos/ros raring main
EOF
wget http://packages.namniart.com/repos/namniart.key -O - | apt-key add -
apt-get update
apt-get -y install ros-hydro-ros-base python-rosdep
apt-get clean
rosdep init
rosdep update
echo "source /opt/ros/hydro/setup.bash" >> ~/.bashrc
source /opt/ros/hydro/setup.bash
mkdir -p ~/catkin_ws/src
cd ~/catkin_ws/src
catkin_init_workspace
cd
mkdir libs
cd libs
apt-get install -y build-essential make libjpeg8-dev libjpeg8 pkg-config vflib3 vflib3-dev libfontconfig1-dev libfontconfig1 libfribidi-dev libfribidi0 git xorg-dev xutils-dev x11proto-dri2-dev libltdl-dev libtool automake libdrm-dev autoconf xutils-dev libgif4 libgif-dev debhelper dh-autoreconf pkg-config libpng12-0 libpng12-dev libtiff5 libtiff5-dev libperl-dev libgtk2.0-dev libpulse0 libpulse-dev libsndfile1 libsndfile1-dev x11proto-print-dev libxp-dev libxp6 libudev-dev libudev1 libmount-dev libmount1 libblkid-dev libbullet-dev bison flex libgles2-mesa-dev libluajit-5.1-dev libts-0.0-0 libdbus-glib-1-2 libdbus-glib-1-dev
apt-get clean

# http://linux-sunxi.org/Xorg#fbturbo_driver
# http://linux-sunxi.org/Binary_drivers
# https://github.com/ssvb/xf86-video-fbturbo/wiki/Installation
git clone https://github.com/ssvb/xf86-video-fbturbo.git
cd xf86-video-fbturbo
autoreconf -vi
./configure --prefix=/usr
make
make install
cp xorg.conf /etc/X11/xorg.conf
cd ..
rm -Rf xf86-video-fbturbo

git clone https://github.com/linux-sunxi/libump.git
cd libump
dpkg-buildpackage -b
dpkg -i ../libump*.deb
cd ..
rm -Rf libump

git clone https://github.com/robclark/libdri2
cd libdri2
./autogen.sh
./configure
make
make install
ldconfig
cd ..
rm -Rf libdri2

git clone https://github.com/linux-sunxi/sunxi-mali.git
cd sunxi-mali
# fix for being able to build efl later
git pull https://github.com/raoulh/sunxi-mali/
git submodule init
git submodule update
ABI=armhf VERSION=r3p0 make config
make install
cd ..
rm -Rf sunxi-mali


wget http://luajit.org/download/LuaJIT-2.0.3.tar.gz
tar zxf LuaJIT-2.0.3.tar.gz
cd LuaJIT-2.0.3
make
make install
make clean
cd ..
rm -Rf LuaJIT-2.0.3 LuaJIT-2.0.3.tar.gz

wget http://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.4.3.tar.xz
tar xJf gstreamer-1.4.3.tar.xz
cd gstreamer-1.4.3
./configure
make
make install
cd ..
rm -Rf gstreamer-1.4.3 gstreamer-1.4.3.tar.xz

wget http://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-1.4.3.tar.xz
tar xJf gst-plugins-base-1.4.3.tar.xz
cd gst-plugins-base-1.4.3
./configure
make
make install
cd ..
rm -Rf gst-plugins-base-1.4.3 gst-plugins-base-1.4.3.tar.xz

wget http://download.enlightenment.org/rel/libs/efl/efl-1.11.2.tar.gz
tar xzf efl-1.11.2.tar.gz
cd efl-1.11.2
./configure --prefix=/usr CFLAGS='-march=armv7-a -mtune=cortex-a8 -mfloat-abi=hard -mfpu=neon -O2 -g' CXXFLAGS='-march=armv7-a -mtune=cortex-a8 -mfloat-abi=hard -mfpu=neon -O2 -g'
make
make install
cd ..
rm -Rf xzf efl-1.11.2.tar.gz efl-1.11.2

wget http://dbus.freedesktop.org/releases/dbus-python/dbus-python-0.84.0.tar.gz
tar xzf dbus-python-0.84.0.tar.gz
cd dbus-python-0.84.0
./configure
make
make install
cd ..
rm -Rf dbus-python-0.84.0 dbus-python-0.84.0.tar.gz

wget http://download.enlightenment.org/rel/libs/elementary/elementary-1.11.2.tar.gz
tar xzf elementary-1.11.2.tar.gz
cd elementary-1.11.2
./configure --prefix=/usr
make
make install
wget http://download.enlightenment.org/rel/bindings/python/python-efl-1.11.0.tar.gz
tar xzf python-efl-1.11.0.tar.gz
cd python-efl-1.11.0
python setup.py build
python setup.py install
cd ..
rm -Rf python-efl-1.11.0 python-efl-1.11.0.tar.gz

# http://olimex.wordpress.com/2012/12/19/a13-lcd7ts-support-in-linux/
#git clone https://github.com/kergoth/tslib
#cd tslib
#wget https://raw.githubusercontent.com/OLIMEX/OLINUXINO/master/SOFTWARE/A13/TOUCHSCREEN/tslib.patch
#patch -p1 < tslib.patch
#autoreconf -vi
#./configure
#make
#make install


mkdir /usr/lib/arm-linux-gnueabihf/bak
mv /usr/lib/arm-linux-gnueabihf/libGLES* /usr/lib/arm-linux-gnueabihf/bak
mv /usr/lib/arm-linux-gnueabihf/libEGL* /usr/lib/arm-linux-gnueabihf/bak

cd ..
rm -Rf libs

EOT


chmod +x $MOUNT/root/finish.sh
LC_ALL=C LANGUAGE=C LANG=C chroot $MOUNT /root/finish.sh

#exit

rm $MOUNT/root/finish.sh

sync

echo === umount ===
for i in $mnt_devices ; do
  umount -l "$MOUNT"/$i
done

rm $MOUNT/etc/resolv.conf
rm $MOUNT/usr/bin/qemu-arm-static

sync
sleep 10
umount -l $MOUNT

kpartx -d $SDIMG_FILE

END=`date +"%s"`
echo -n "image build duration: "
show_time $START $END
