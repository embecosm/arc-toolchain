#!/bin/sh

# Copyright (C) 2010-2015 Synopsys Inc.

# Contributor Brendan Kehoe <brendan@zen.org>
# Contributor Jeremy Bennett <jeremy.bennett@embecosm.com>
# Contributor Anton Kolesov <Anton.Kolesov@synopsys.com>

# This file is a master script for ARC tool chains.

# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation; either version 3 of the License, or (at your option)
# any later version.

# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.

# You should have received a copy of the GNU General Public License along
# with this program.  If not, see <http://www.gnu.org/licenses/>.          

#		   SCRIPT TO BUILD ARC-LINUX-UCLIBC TOOLKIT
#		   ========================================

# Usage:

#     ${ARC_GNU}/toolchain/build_uclibc.sh [--force]

# --force

#     Blow away any old build sub-directories

# The directory in which we are invoked is the build directory, in which we
# find the unified source tree and in which all build directories are created.

# All other parameters are set by environment variables.

# LOGDIR

#     Directory for all log files.

# ARC_GNU

#     The directory containing all the sources. If not set, this will default
#     to the directory containing this script.

# LINUXDIR

#     The name of the Linux directory (absolute path)

# INSTALLDIR

#     The directory where the tool chain should be installed

# ARC_ENDIAN

#     "little" or "big"

# UCLIBC_DISABLE_MULTILIB

#     Either --enable-multilib or --disable-multilib to control the building
#     of multilibs.

# UCLIBC_DEFCFG

#     The defconfig to be used when building uClibc. That should a name of file
#     that is inside uClibc/extra/Configs/defconfig/arc directory.

# ISA_CPU

#     Specifies target ARC core, can be arc700 or archs.

# CONFIG_EXTRA

#     Additional flags for use with configuration.

# CFLAGS_FOR_TARGET

#     Additional flags used when building the target libraries (e.g. for
#     compact libraries) picked up automatically by make. This variable is used
#     by configure scripts and make, and build-uclibc.sh doesn't do anything
#     about it explicitly.

# DO_PDF

#     Either --pdf or --no-pdf to control whether we build and install PDFs of
#     the user guides.

# PARALLEL

#     string "-j <jobs> -l <load>" to control parallel make.

# HOST_INSTALL

#     Make target prefix to install host application. Should be either
#     "install" or "install-strip".

# TLS_SUPPORT

#     Build with threading and thread local storage support if this is
#     set to "yes".

# We source the script arc-init.sh to set up variables needed by the script
# and define a function to get to the configuration directory (which can be
# tricky under MinGW/MSYS environments).

# The script generates a date and time stamped log file in the logs directory.

# Approach is following:
# 1. Install Linux headers
# 2. Install uClibc headers
# 3. Build and install Binutils
# 4. Build and install GCC stage 1 (without C++)
# 5. Build and install uClibc
# 6. Build and install GCC stage 2 (with C++)
# 7. Build and install GDB
# 8. Build and copy GDB-server for target

# Following after this paragraph text, is a text of historical significance
# that described how things used to be done in the age of ARC GCC 4.4 and early
# days of ARC GCC 4.8. Things changed since then so this is not totally
# relevant today, but explains how things evolved, since some things today can
# be done differently then they are done right now, because it was an evolution
# of previous decisions. For example it seems that we can install Linux and
# uClibc headers after stage 1 instead of doing this as a first step.  Although
# that might be true in general, but not for ARC, since our libgcc depends on
# libc headers. To be completely honest I haven't read this header guide while
# modifying toolchain to support sysroot and avoid unified source tree, as I
# was just looking at the code itself, and was completely oblivious to the
# presence of this gentoo web-guide... (On the matter of comments in code: will
# anybody read this???).

# << How it used to be done: >>

# This approach is based on Mike Frysinger's guidelines on building a
# cross-compiler.

#     http://dev.gentoo.org/~vapier/CROSS-COMPILE-GUTS

# However this seems to have a basic flaw, because it relies on using sysroot,
# and for older versions of GCC (4.4.x included), the build of libgcc does not
# take any notice of sysroot.

# This has been extended to uClibc and brought up to date, using the
# install-headers targets of Linux and uClibc.

# The basic approach recommended by Frysinger is:

# 1. Build binutils
# 2. Install the Linux kernel headers
# 3. Install the uClibc headers
# 4. Build gcc stage 1 (C only)
# 5. Build uClibc
# 6. Build gcc stage 2 (C, C++ etc)

# We create a sysroot, where we can put our intermediate stuff. However there
# is a catch with GCC 4.4.7 (fixed in in GCC 4.7) that libgcc is muddled up in
# gcc and doesn't seem to recognize the sysroot. So we have to also install
# headers in the install directory before building libgcc.

# So we use a revised flow.

# 1. Install the Linux kernel headers into the temporary directory
# 2. Install uClibc headers into the temporary directory using host GCC
# 3. Build and install GCC stage 1 without headers into temporary directory
# 4. Build & install uClibc using the stage 1 compiler into the final directory
# 5. Build & install the whole tool chain from scratch (including GCC stage 2)
#    using the temporary headers

# We build GDB after GCC. gdbserver also has to be built and installed
# separately. So we add two extra steps

# 6. Build & install GDB
# 7. Build & install gdbserver

# << End of history lesson >>


# -----------------------------------------------------------------------------
# Local variables.
if [ "${ARC_ENDIAN}" = "big" ]
then
    arche=arceb
    build_dir="$(echo "${PWD}")/bd-uclibceb"
else
    arche=arc
    build_dir="$(echo "${PWD}")/bd-uclibc"
fi

arch=arc
triplet=${arche}-snps-linux-uclibc

if [ $ISA_CPU = arc700 ]
then
    version_str="ARCompact ISA Linux uClibc toolchain $RELEASE_NAME"
else
    version_str="ARCv2 ISA Linux uClibc toolchain $RELEASE_NAME"
fi
bugurl_str="http://solvnet.synopsys.com"

# parse options
until
opt=$1
case ${opt} in
    --force)
	rm -rf ${build_dir}
	;;
    ?*)
	echo "Usage: ./build-uclibc.sh [--force]"
	exit 1
	;;
esac
[ -z "${opt}" ]
do
    shift
done

# Set up a logfile
logfile="${LOGDIR}/uclibc-build-$(date -u +%F-%H%M).log"
rm -f "${logfile}"

echo "START ${ARC_ENDIAN}-endian uClibc: $(date)" | tee -a ${logfile}

# Initalize, including getting the tool versions. Note that we don't need
# newlib for now if we rebuild our unified source tree.
. "${ARC_GNU}"/toolchain/arc-init.sh
uclibc_build_dir="$(echo "${PWD}")"/uClibc
linux_build_dir=${LINUXDIR}

# If PDF docs are enabled, then check if prerequisites are satisfied.
if [ "x${DO_PDF}" = "x--pdf" ]
then
    if ! which texi2pdf >/dev/null 2>/dev/null ; then
	echo "TeX is not installed. See README.md for a list of required"
	echo "system packages. Option --no-pdf can be used to disable build"
	echo "of PDF documentation."
	exit 1
    fi

    # There are issues with Texinfo v4 and non-C locales.
    # See http://lists.gnu.org/archive/html/bug-texinfo/2010-03/msg00031.html
    if [ 4 = `texi2dvi --version | grep -Po '(?<=Texinfo )[0-9]+'` ]; then
	export LC_ALL=C
    fi
fi

# Note stuff for the log
echo "Installing in ${INSTALLDIR}" | tee -a ${logfile}

# Setup vars
SYSROOTDIR=${INSTALLDIR}/${triplet}/sysroot
DEFCFG_DIR=extra/Configs/defconfigs/arc/

# -----------------------------------------------------------------------------
# Install the Linux headers

echo "Installing Linux headers ..." | tee -a "${logfile}"
echo "============================" >> "${logfile}"

cd "${linux_build_dir}"

# Configure Linux if not already
if [ ! -f .config ]; then
    if make ARCH=${arch} defconfig >> "${logfile}" 2>&1
    then
	echo "  finished configuring Linux"
    else
	echo "ERROR: Linux configuration was not successful. Please"
	echo "       see \"${logfile}\" for details."
	exit 1
    fi
else
    echo "  Linux already configured"
fi

if make ARCH=${arch} INSTALL_HDR_PATH=${SYSROOTDIR}/usr \
    headers_install >> "${logfile}" 2>&1
then
    echo "  finished installing Linux headers"
else
    echo "ERROR: Linux header install was not successful. Please see"
    echo "       \"${logfile}\" for details."
    exit 1
fi

# -----------------------------------------------------------------------------
# Install uClibc headers for the Stage 1 compiler. This needs a C compiler,
# which we do not yet have. We get round this by using the native C
# compiler. uClibc will complain, but get on with the job anyway.

echo "Installing uClibc headers ..." | tee -a "${logfile}"
echo "=============================" >> "${logfile}"

# uClibc builds in place, so if ${ARC_GNU} is set (to a different location) we
# have to create the directory and copy the source across.
mkdir -p ${uclibc_build_dir}
cd ${uclibc_build_dir}

if [ ! -f Makefile.in ]
then
    echo Copying over uClibc sources
    tar -C "${ARC_GNU}"/uClibc --exclude=.svn --exclude='*.o' \
	--exclude='*.a' -cf - . | tar -xf -
fi

# make will fail if there is yet no .config file, but we can ignore this error.
make distclean >> "${logfile}" 2>&1 || true 

# Copy the defconfig file to a temporary location
TEMP_DEFCFG=`mktemp --tmpdir=${DEFCFG_DIR} XXXXXXXXXX_defconfig`
if [ ! -f "${TEMP_DEFCFG}" ]
then
    echo "ERROR: Failed to create temporary defconfig file."
    exit 1
fi
cp ${DEFCFG_DIR}${UCLIBC_DEFCFG} ${TEMP_DEFCFG}

# Patch defconfig with the temporary install directories used.
${SED} -e "s#%KERNEL_HEADERS%#${SYSROOTDIR}/usr/include#" \
       -e "s#%RUNTIME_PREFIX%#/#" \
       -e "s#%DEVEL_PREFIX%#/usr/#" \
       -e "s#CROSS_COMPILER_PREFIX=\".*\"#CROSS_COMPILER_PREFIX=\"${triplet}-\"#" \
       -i ${TEMP_DEFCFG}

# Patch defconfig for big or little endian.
if [ "${ARC_ENDIAN}" = "big" ]
then
    ${SED} -e 's@ARCH_WANTS_LITTLE_ENDIAN=y@ARCH_WANTS_BIG_ENDIAN=y@' \
           -i ${TEMP_DEFCFG}
else
    ${SED} -e 's@ARCH_WANTS_BIG_ENDIAN=y@ARCH_WANTS_LITTLE_ENDIAN=y@' \
           -i ${TEMP_DEFCFG}
fi

# Patch the defconfig for thread support.
if [ "x${TLS_SUPPORT}" = "xyes" ]
then
    ${SED} -e 's@LINUXTHREADS_OLD=y@UCLIBC_HAS_THREADS_NATIVE=y@' \
           -i ${TEMP_DEFCFG}
fi

# Create the .config from the temporary defconfig file.
make ARCH=arc `basename ${TEMP_DEFCFG}` >> "${logfile}" 2>&1

# Now remove the temporary defconfig file.
rm -f ${TEMP_DEFCFG}

# PREFIX is an arg to Makefile, it is not set in .config.
if make ARCH=${arch} V=1 PREFIX=${SYSROOTDIR} install_headers >> "${logfile}" 2>&1
then
    echo "  finished installing uClibc headers"
else
    echo "ERROR: uClibc header install was not successful. Please see"
    echo "       \"${logfile}\" for details."
    exit 1
fi

if [ "x${TLS_SUPPORT}" = "xyes" ]
then
    thread_flags="--enable-threads --enable-tls"
else
    thread_flags="--disable-threads --disable-tls"
fi

# -----------------------------------------------------------------------------
# Build Binutils - will be used by both state 1 and stage2
# Note about separate install-gas: Gas installation depends on libopcodes - if
# it detects that opcodes hasn't been yet installed, then install-gas will
# install dummy "as" script instead of proper binary. However GNU makefile
# doesn't describe this dependency, so in parallel installation there is a
# chance that install-gas will run before install-opcodes, which will cause a
# broken gas installation. Workaround is to call install-gas separately, after
# other targets. libopcodes is a dependency of binutils (target, not package),
# so as long as install-gas is done after install-binutils it should be safe.
build_dir_init binutils
configure_uclibc_stage2 binutils
make_target building all-binutils all-gas all-ld
make_target installing install-{binutils,ld}
make_target "installing gas" install-gas
if [ $DO_PDF == --pdf ]; then
    make_target "generating PDF documentation" install-pdf-{binutils,ld,gas}
fi

# -----------------------------------------------------------------------------
# Add tool chain to the path for now, since binutils is required to build
# libgcc, while GCC stage 1 will be required to build uClibc, but remember the
# old path for restoring later.
oldpath=${PATH}
PATH=${INSTALLDIR}/bin:$PATH
export PATH

# -----------------------------------------------------------------------------
# Build stage 1 GCC
build_dir_init gcc-stage1
configure_uclibc_stage1 gcc
make_target building all-{gcc,target-libgcc}
make_target installing ${HOST_INSTALL}-gcc install-target-libgcc
# No need for PDF docs for stage 1.

# -----------------------------------------------------------------------------
# Build uClibc using the stage 1 compiler.

echo "Building uClibc ..." | tee -a "${logfile}"
echo "===================" >> "${logfile}"

# We don't need to create directories or copy source, since that is already
# done when we got the headers.
cd ${uclibc_build_dir}

# Copy the defconfig file to a temporary location
TEMP_DEFCFG=`mktemp --tmpdir=${DEFCFG_DIR} XXXXXXXXXX_defconfig`
if [ ! -f "${TEMP_DEFCFG}" ]
then
    echo "ERROR: Failed to create temporary defconfig file."
    exit 1
fi
cp ${DEFCFG_DIR}${UCLIBC_DEFCFG} ${TEMP_DEFCFG}

# Patch defconfig with the temporary install directories used.
${SED} -e "s#%KERNEL_HEADERS%#${SYSROOTDIR}/usr/include#" \
       -e "s#%RUNTIME_PREFIX%#/#" \
       -e "s#%DEVEL_PREFIX%#/usr/#" \
       -e "s#CROSS_COMPILER_PREFIX=\".*\"#CROSS_COMPILER_PREFIX=\"${triplet}-\"#" \
       -i ${TEMP_DEFCFG}

# At this step we also disable HARDWIRED_ABSPATH to avoid absolute
# path references to allow relocatable toolchains.
echo "HARDWIRED_ABSPATH=n" >> ${TEMP_DEFCFG}

# Patch defconfig for big or little endian.
if [ "${ARC_ENDIAN}" = "big" ]
then
    ${SED} -e 's@ARCH_WANTS_LITTLE_ENDIAN=y@ARCH_WANTS_BIG_ENDIAN=y@' \
           -i ${TEMP_DEFCFG}
else
    ${SED} -e 's@ARCH_WANTS_BIG_ENDIAN=y@ARCH_WANTS_LITTLE_ENDIAN=y@' \
           -i ${TEMP_DEFCFG}
fi

# Patch the defconfig for thread support.
if [ "x${TLS_SUPPORT}" = "xyes" ]
then
    ${SED} -e 's@LINUXTHREADS_OLD=y@UCLIBC_HAS_THREADS_NATIVE=y@' \
           -i ${TEMP_DEFCFG}
fi

# Create the .config from the temporary defconfig file.
make ARCH=arc `basename ${TEMP_DEFCFG}` >> "${logfile}" 2>&1

# Now remove the temporary defconfig file.
rm -f ${TEMP_DEFCFG}

if make ARCH=${arch} clean >> "${logfile}" 2>&1
then
    echo "  finished cleaning uClibc"
else
    echo "ERROR: uClibc clean was not successful. Please see"
    echo "       \"${logfile}\" for details."
    exit 1
fi

# PREFIX is an arg to Makefile, it is not set in .config.
if make ARCH=${arch} V=2 PREFIX=${SYSROOTDIR} >> "${logfile}" 2>&1
then
    echo "  finished building uClibc"
else
    echo "ERROR: uClibc build was not successful. Please see"
    echo "       \"${logfile}\" for details."
    exit 1
fi

if make ARCH=${arch} V=2 PREFIX=${SYSROOTDIR} install >> "${logfile}" 2>&1
then
    echo "  finished installing uClibc"
else
    echo "ERROR: uClibc install was not successful. Please see"
    echo "       \"${logfile}\" for details."
    exit 1
fi

# Restore the search path
PATH=${oldpath}
unset oldpath

# -----------------------------------------------------------------------------
# GCC stage 2
build_dir_init gcc-stage2
configure_uclibc_stage2 gcc
make_target building all-{gcc,target-libgcc,target-libstdc++-v3}
make_target installing ${HOST_INSTALL}-gcc install-{target-libgcc,target-libstdc++-v3}
if [ "$DO_PDF" = "--pdf" ]; then
    make_target "generating PDF documentation" install-pdf-gcc
fi

# Despite "--with-sysroot" libgcc and libstdc++ will be installed to default
# directory. Copy them manually. It also looks like that buildroot will work
# properly even without this change and will copy libraries to the target
# system appropriately in any way. However Buildroot does this step with its
# internal toolchain and I'm mimicking this. Also this might help if one want
# to have multiple sysroots. In that latter case I suppose that libraries
# outside of sysroots should be removed to avoid unintentional mixing. Also my
# experiments showed that G++ can't find libstdc++ headers in sysroot, they
# should be where they've been installed.
cp -dpf ${INSTALLDIR}/${triplet}/lib/libgcc_s* ${SYSROOTDIR}/lib/
cp -dpf ${INSTALLDIR}/${triplet}/lib/libstdc++*.so* ${SYSROOTDIR}/usr/lib
cp -dpf ${INSTALLDIR}/${triplet}/lib/libstdc++*.a ${SYSROOTDIR}/usr/lib

# Add the newly created tool chain to the path
PATH=${INSTALLDIR}/bin:$PATH
export PATH

# -----------------------------------------------------------------------------
# Build and install GDB
build_dir_init gdb
configure_uclibc_stage2 gdb
make_target building all-gdb
make_target installing install-gdb
if [ "$DO_PDF" = "--pdf" ]; then
    make_target "generating PDF documentation" install-pdf-gdb
fi

# -----------------------------------------------------------------------------
# Create symlinks
echo "Creating symlinks ..." | tee -a "${logfile}"
echo "=====================" >> "${logfile}"

cd ${INSTALLDIR}/bin
for i in ${triplet}-*
do
    ln -fs $i $(echo $i | sed "s/${triplet}/${arche}-linux/")
    ln -fs $i $(echo $i | sed "s/${triplet}/${arche}-linux-uclibc/")
done

echo "  finished creating symlinks"

# -----------------------------------------------------------------------------
# gdbserver has to be built on its own.

echo "Building gdbserver to run on an ARC ..." | tee -a "${logfile}"
echo "=======================================" >> "${logfile}"

build_dir_init gdbserver

config_path=$(calcConfigPath "${ARC_GNU}")/gdb/gdb/gdbserver
if "${config_path}"/configure \
        --with-pkgversion="${version_str}"\
        --with-bugurl="${bugurl_str}" \
        --host=${triplet} >> "${logfile}" 2>> "${logfile}"
then
    echo "  finished configuring gdbserver"
else
    echo "ERROR: gdbserver configure failed. Please see"
    echo "       \"${logfile}\" for details."
    exit 1
fi

CC=${triplet}-gcc
export CC
if make ${PARALLEL} \
    CFLAGS="-static -fcommon -mno-sdata -O3 ${CFLAGS_FOR_TARGET}" \
    >> "${logfile}" 2>&1
then
    echo "  finished building gdbserver to run on an arc"
else
    echo "ERROR: gdbserver build was not successful. Please see"
    echo "       \"${logfile}\" for details."
    exit 1
fi

mkdir -p ${INSTALLDIR}/target-bin
if cp gdbserver ${INSTALLDIR}/target-bin
then
    echo "  finished installing gdbserver to run on an ARC"
else
    echo "ERROR: gdbserver install was not successful. Please see"
    echo "       \"${logfile}\" for details."
    exit 1
fi

echo "DONE  UCLIBC: $(date)" | tee -a "${logfile}"

# vim: noexpandtab sts=4 ts=8:
