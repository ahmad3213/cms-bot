#!/bin/bash -ex

function check_missing_provides() {
  rm -f rpms.txt ; touch rpms.txt
  grep ' is needed by ' $1 | while IFS= read -r line; do
    pkg=$(echo "$line" | sed 's|.*needed by *||' | cut -d+ -f2)
    provide=$(echo "$line" | sed 's| *is needed by .*||;s|^\s*||')
    r=$(rpm -q --whatprovides "$provide" --queryformat='%{NAME}' 2>&1 | grep -v 'no package provides')
    if [ "${r}" != "" ] ; then echo $r >> rpms.txt; fi
    if [ "${opkg}" != "${pkg}" ] ; then
      echo "==== $pkg.spec ===="
      opkg=$pkg
    fi
    echo "Provides: ${provide}"
  done
  cat rpms.txt | sort | uniq | tr '\n' ' '
  rm -rf rpms.txt
}

function get_logs() {
  mkdir -p upload/$1
  [ -e $1/tmp/bootstrap.log ] && cp $1/tmp/bootstrap.log upload/$1
  for l in $(find $1/BUILD/${ARCH} -maxdepth 4 -mindepth 4 -name log -type f | sed "s|$1/BUILD/${ARCH}/||") ; do
    d=$(dirname $l)
    mkdir -p upload/$1/$d
    mv $1/BUILD/${ARCH}/$l upload/$1/$d
  done
}

ARCH=$1
PKGTOOLS=$2
CMSDIST=$3
REPO="$4"
DISABLE_DEBUG="$5"
CMSSW_VERSION="$6"
GCC_PATH="$7"
SKIP_BOOTSTRAP="$8"
BS_OPTS="--no-bootstrap"
if [ "${REPO}" = "" ] ; then REPO="test_boot_$ARCH" ; fi
if ssh -q -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=60 cmsbuild@cmsrep.cern.ch test -L /data/cmssw/repos/$REPO/${ARCH}/latest ; then
  BS_OPTS=""
  GCC_PATH=""
fi
[ "${GCC_PATH}" != "" ] || GCC_PATH="NO_GCC_PATH"

if [ -e "$HOME/bin/nproc" ] ; then export PATH="${HOME}/bin:${PATH}" ; fi
cmsBuild="./pkgtools/cmsBuild --repo $REPO -a $ARCH -j $(nproc)"

git clone --depth 1 https://github.com/cms-sw/cmsdist -b $CMSDIST
git clone --depth 1 https://github.com/cms-sw/pkgtools -b $PKGTOOLS

mkdir -p upload
if ! $SKIP_BOOTSTRAP ; then
  type="bootstrap"
  ([ -f "${GCC_PATH}/etc/profile.d/init.sh" ] && source ${GCC_PATH}/etc/profile.d/init.sh ; $cmsBuild -i ${type} ${BS_OPTS} build bootstrap-driver | tee -a upload/${type}-build.log)
  get_logs ${type}
  $cmsBuild -i ${type} ${BS_OPTS} --sync-back upload bootstrap-driver | tee -a upload/${type}-upload.log
  rm -rf bootstrap
fi

if [ "${DISABLE_DEBUG}" = "true" ] ; then
  sed -i -e 's|^\s*%define\s\s*subpackageDebug\s|#subpackage debug disabled|' cmsdist/coral.spec cmsdist/cmssw.spec
fi
ERR=0
type="toolconf"
$cmsBuild -i ${type} --builder 3  build cmssw-tool-conf | tee -a upload/${type}-build.log || ERR=1
get_logs ${type}
if [ $ERR -gt 0 ] ; then
  set +x; check_missing_provides upload/${type}-build.log ; set -x
  BLD_PKGS=$(ls ${type}/RPMS/${ARCH}/ | grep '.rpm$' | cut -d+ -f2 | grep -v 'coral-debug')
  if [ "X$BLD_PKGS" != "X" ] ; then $cmsBuild -i ${type} --builder 3  --sync-back upload ${BLD_PKGS} | tee -a upload/${type}-upload.log ; fi
  rm -rf ${type}
  exit 1
fi
$cmsBuild -i ${type} --builder 3 --sync-back upload cmssw-tool-conf | tee -a upload/${type}-upload.log
rm -rf ${type}

if [ "$CMSSW_VERSION" != "" ] ; then
  sed -i -e "s|^### RPM cms cmssw .*|### RPM cms cmssw $CMSSW_VERSION|"       cmsdist/cmssw.spec
  sed -i -e "s|^### RPM cms cmssw-ib .*|### RPM cms cmssw-ib $CMSSW_VERSION|" cmsdist/cmssw-ib.spec
  type="release"
  $cmsBuild -i ${type} build cmssw-ib | tee -a upload/${type}-build.log
  get_logs ${type}
  $cmsBuild -i ${type} --sync-back upload cmssw-ib | tee -a upload/${type}-upload.log
  rm -rf ${type}
fi