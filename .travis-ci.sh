#!/bin/bash -xue

OPAMBSVERSION=2.1.0-alpha
OPAMBSROOT=$HOME/.opam.cached
OPAMBSSWITCH=opam-build
PATH=~/local/bin:$PATH; export PATH

TARGET="$1"; shift

COLD=${COLD:-0}
OPAM_TEST=${OPAM_TEST:-0}
EXTERNAL_SOLVER=${EXTERNAL_SOLVER:-}

set +x
echo "TRAVIS_COMMIT_RANGE=$TRAVIS_COMMIT_RANGE"
echo "TRAVIS_COMMIT=$TRAVIS_COMMIT"
if [[ $TRAVIS_EVENT_TYPE = 'pull_request' ]] ; then
  FETCH_HEAD=$(git rev-parse FETCH_HEAD)
  echo "FETCH_HEAD=$FETCH_HEAD"
else
  FETCH_HEAD=$TRAVIS_COMMIT
fi

if [[ $TRAVIS_EVENT_TYPE = 'push' ]] ; then
  if ! git cat-file -e "$TRAVIS_COMMIT" 2> /dev/null ; then
    echo 'TRAVIS_COMMIT does not exist - CI failure'
    exit 1
  fi
else
  if [[ $TRAVIS_COMMIT != $(git rev-parse FETCH_HEAD) ]] ; then
    echo 'WARNING! Travis TRAVIS_COMMIT and FETCH_HEAD do not agree!'
    if git cat-file -e "$TRAVIS_COMMIT" 2> /dev/null ; then
      echo 'TRAVIS_COMMIT exists, so going with it'
    else
      echo 'TRAVIS_COMMIT does not exist; setting to FETCH_HEAD'
      TRAVIS_COMMIT=$FETCH_HEAD
    fi
  fi
fi
set -x

init-bootstrap () {
  export OPAMROOT=$OPAMBSROOT
  # The system compiler will be picked up
  opam init --yes --no-setup
  eval $(opam env)
  opam update
  CURRENT_SWITCH=$(opam config var switch)
  if [[ $CURRENT_SWITCH != "default" ]] ; then
    opam switch default
    eval $(opam env)
    opam switch remove $CURRENT_SWITCH --yes
  fi

  if [ "$OPAM_TEST" = "1" ]; then
    opam switch create $OPAMBSSWITCH ocaml-system
    eval $(opam env)
    # extlib is installed, since UChar.cmi causes problems with the search
    # order. See also the removal of uChar and uTF8 in src_ext/jbuild-extlib-src
    opam install ssl cmdliner dose3 cudf.0.9 opam-file-format re extlib dune 'mccs>=1.1+5' --yes
  fi
  rm -f "$OPAMBSROOT"/log/*
}

CheckConfigure () {
  GIT_INDEX_FILE=tmp-index git read-tree --reset -i "$1"
  git diff-tree --diff-filter=d --no-commit-id --name-only -r "$1" \
    | (while IFS= read -r path
  do
    case "$path" in
      configure|configure.ac|m4/*)
        touch CHECK_CONFIGURE;;
    esac
  done)
  rm -f tmp-index
  if [[ -e CHECK_CONFIGURE ]] ; then
    echo "configure generation altered in $1"
    echo 'Verifying that configure.ac generates configure'
    git clean -dfx
    git checkout -f "$1"
    mv configure configure.ref
    make configure
    if ! diff -q configure configure.ref >/dev/null ; then
      echo -e "[\e[31mERROR\e[0m] configure.ac in $1 doesn't generate configure, \
please run make configure and fixup the commit"
      ERROR=1
    fi
  fi
}

case "$TARGET" in
  prepare)
    if [ "$TRAVIS_BUILD_STAGE_NAME" = "Hygiene" ] ; then
      exit 0
    fi
    make --version
    mkdir -p ~/local/bin

    # Git should be configured properly to run the tests
    git config --global user.email "travis@example.com"
    git config --global user.name "Travis CI"
    git config --global gc.autoDetach false

  # Disable bubblewrap wrapping, it's not available within Docker
  cat <<EOF >>~/.opamrc
required-tools: [
  ["curl" "wget"]
    {"A download tool is required, check env variables OPAMCURL or OPAMFETCH"}
  "diff"
  "patch"
  "tar"
  "unzip"
]
wrap-build-commands: []
wrap-install-commands: []
wrap-remove-commands: []
EOF

    if [[ $COLD -eq 1 ]] ; then
      if [ ! -x ~/local/bin/make ] ; then
        wget http://ftpmirror.gnu.org/gnu/make/make-4.2.tar.gz
        tar -xzf make-4.2.tar.gz
        mkdir make-4.2-build
        cd make-4.2-build
        ../make-4.2/configure --prefix ~/local
        make
        make install
        cd ..
      fi
    else
      if [[ $TRAVIS_OS_NAME = "osx" && -n $EXTERNAL_SOLVER ]] ; then
        rvm install ruby-2.3.3
        rvm --default use 2.3.3
        brew install "$EXTERNAL_SOLVER"
      fi

      if [[ -e ~/local/versions ]] ; then
        . ~/local/versions
        if [[ $LOCAL_OCAML_VERSION != $OCAML_VERSION ]] ; then
          echo "Cached compiler is $LOCAL_OCAML_VERSION; requested $OCAML_VERSION"
          echo "Resetting local cache"
          rm -rf ~/local
        elif [[ ${LOCAL_OPAMBSVERSION:-$OPAMBSVERSION} != $OPAMBSVERSION ]] ; then
          echo "Cached opam is $LOCAL_OPAMBSVERSION; requested $OPAMBSVERSION"
          echo "Replacement opam will be downloaded"
          rm -f ~/local/bin/opam-bootstrap
        fi
      fi

      if ! diff -q src_ext/Makefile src_ext/archives/Makefile 2>/dev/null || \
         ! diff -q src_ext/Makefile.sources src_ext/archives/Makefile.sources 2>/dev/null ; then
        echo "lib-ext/lib-pkg package may have been altered - resetting cache"
        rm -rf src_ext/archives
        make -C src_ext cache-archives
        cp src_ext/Makefile src_ext/archives/Makefile
        cp src_ext/Makefile.sources src_ext/archives/Makefile.sources
      fi
    fi
    exit 0
    ;;
  install)
    if [ "$TRAVIS_BUILD_STAGE_NAME" = "Hygiene" ] ; then
      exit 0
    fi
    if [[ $COLD -eq 1 ]] ; then
      make compiler
      make lib-pkg
    else
      if [[ ! -x ~/local/bin/ocaml ]] ; then
        echo -en "travis_fold:start:ocaml\r"
        wget "http://caml.inria.fr/pub/distrib/ocaml-${OCAML_VERSION%.*}/ocaml-$OCAML_VERSION.tar.gz"
        tar -xzf "ocaml-$OCAML_VERSION.tar.gz"
        cd "ocaml-$OCAML_VERSION"
        if [[ $OPAM_TEST -ne 1 ]] ; then
          if [[ -e configure.ac ]]; then
            CONFIGURE_SWITCHES="--disable-debugger --disable-debug-runtime --disable-ocamldoc"
            if [[ ${OCAML_VERSION%.*} = '4.08' ]]; then
              CONFIGURE_SWITCHES="$CONFIGURE_SWITCHES --disable-graph-lib"
            fi
          else
            CONFIGURE_SWITCHES="-no-graph -no-debugger -no-ocamldoc"
            if [[ "$OCAML_VERSION" != "4.02.3" ]] ; then
              CONFIGURE_SWITCHES="$CONFIGURE_SWITCHES -no-ocamlbuild"
            fi

          fi
        fi
        ./configure --prefix ~/local ${CONFIGURE_SWITCHES:-}
        if [[ $OPAM_TEST -eq 1 ]] ; then
          make -j 4 world.opt
        else
          make world.opt
        fi
        make install
        echo "LOCAL_OCAML_VERSION=$OCAML_VERSION" > ~/local/versions
        echo -en "travis_fold:end:ocaml\r"
      fi

      if [[ $OPAM_TEST -eq 1 ]] ; then
        echo -en "travis_fold:start:opam\r"
        if [[ ! -e ~/local/bin/opam-bootstrap ]] ; then
          os=$( (uname -s || echo unknown) | awk '{print tolower($0)}')
          if [ "$os" = "darwin" ] ; then
            os=macos
          fi
          wget -q -O ~/local/bin/opam-bootstrap \
            "https://github.com/ocaml/opam/releases/download/$OPAMBSVERSION/opam-$OPAMBSVERSION-$(uname -m)-$os"
        fi

        cp -f ~/local/bin/opam-bootstrap ~/local/bin/opam
        chmod a+x ~/local/bin/opam

        if [[ -d $OPAMBSROOT ]] ; then
          init-bootstrap || { rm -rf $OPAMBSROOT; init-bootstrap; }
        else
          init-bootstrap
        fi
        echo -en "travis_fold:end:opam\r"
      fi
    fi
    exit 0
    ;;
  build)
    ;;
  *)
    echo "bad command $TARGET"; exit 1
esac

set +x
if [ "$TRAVIS_BUILD_STAGE_NAME" = "Hygiene" ] ; then
  ERROR=0
  if [ "$TRAVIS_EVENT_TYPE" = "pull_request" ] ; then
    TRAVIS_CUR_HEAD=${TRAVIS_COMMIT_RANGE%%...*}
    TRAVIS_PR_HEAD=${TRAVIS_COMMIT_RANGE##*...}
    DEEPEN=50
    while ! git merge-base "$TRAVIS_CUR_HEAD" "$TRAVIS_PR_HEAD" >& /dev/null
    do
      echo "Deepening $TRAVIS_BRANCH by $DEEPEN commits"
      git fetch origin --deepen=$DEEPEN "$TRAVIS_BRANCH"
      ((DEEPEN*=2))
    done
    TRAVIS_MERGE_BASE=$(git merge-base "$TRAVIS_CUR_HEAD" "$TRAVIS_PR_HEAD")
    if ! git diff "$TRAVIS_MERGE_BASE..$TRAVIS_PR_HEAD" --name-only --exit-code -- shell/install.sh > /dev/null ; then
      echo "shell/install.sh updated - checking it"
      eval $(grep '^\(OPAM_BIN_URL_BASE\|DEV_VERSION\|VERSION\)=' shell/install.sh)
      echo "OPAM_BIN_URL_BASE=$OPAM_BIN_URL_BASE"
      echo "VERSION = $VERSION"
      echo "DEV_VERSION = $DEV_VERSION"
      for VERSION in $DEV_VERSION $VERSION; do
        eval $(grep '^TAG=' shell/install.sh)
        echo "TAG = $TAG"
        ARCHES=0

        while read -r key sha
        do
          ARCHES=1
          URL="$OPAM_BIN_URL_BASE$TAG/opam-$TAG-$key"
          echo "Checking $URL"
          check=$(curl -Ls "$URL" | sha512sum | cut -d' ' -f1)
          if [ "$check" = "$sha" ] ; then
            echo "Checksum as expected ($sha)"
          else
            echo -e "[\e[31mERROR\e[0m] Checksum downloaded: $check"
            echo -e "[\e[31mERROR\e[0m] Checksum install.sh: $sha"
            ERROR=1
          fi
        done < <(sed -ne "s/.*opam-$TAG-\([^)]*\).*\"\([^\"]*\)\".*/\1 \2/p" shell/install.sh)
      done
      if [ $ARCHES -eq 0 ] ; then
        echo "[\e[31mERROR\e[0m] No sha512 checksums were detected in shell/install.sh"
        echo "That can't be right..."
        ERROR=1
      fi
    fi
  fi
  if [[ -z $TRAVIS_COMMIT_RANGE ]]
  then CheckConfigure "$TRAVIS_COMMIT"
  else
    if [[ $TRAVIS_EVENT_TYPE = 'pull_request' ]]
    then TRAVIS_COMMIT_RANGE=$TRAVIS_MERGE_BASE..$TRAVIS_PULL_REQUEST_SHA
    fi
    for commit in $(git rev-list "$TRAVIS_COMMIT_RANGE" --reverse)
    do
      CheckConfigure "$commit"
    done
  fi
  # Check that the lib-ext/lib-pkg patches are "simple"
  make -C src_ext PATCH="busybox patch" clone
  make -C src_ext PATCH="busybox patch" clone-pkg
  # Check that the lib-ext/lib-pkg patches have been re-packaged
  cd src_ext
  ../shell/re-patch.sh
  if [[ $(find patches -name \*.old | wc -l) -ne 0 ]] ; then
    echo -e "[\e[31mERROR\e[0m] ../shell/re-patch.sh should be run from src_ext before CI check"
    git diff
    ERROR=1
  fi
  cd ..
  exit $ERROR
fi
set -x

export OPAMYES=1
export OCAMLRUNPARAM=b

( # Run subshell in bootstrap root env to build
  echo -en "travis_fold:start:build\r"
  if [[ $OPAM_TEST -eq 1 ]] ; then
    export OPAMROOT=$OPAMBSROOT
    eval $(opam env)
  fi

  ./configure --prefix ~/local --with-mccs

  if [[ $OPAM_TEST$COLD -eq 0 ]] ; then
    make lib-ext
  fi
  if [ "$TRAVIS_BUILD_STAGE_NAME" = "Upgrade" ]; then
    # unset git versionning to allow OPAMYES use for upgrade
    sed -i  -e 's/\(.*with-stdout-to get-git-version.ml.*@@\).*/\1 \\"let version = None\\"")))/' src/client/dune
  fi
  make all admin

  rm -f ~/local/bin/opam
  make install

  if [ "$OPAM_TEST" = "1" ]; then
    make distclean
    for pin in core format solver repository state client ; do
      opam pin add --kind=path opam-$pin . --yes
    done
    # Compile and run opam-rt
    cd ~/build
    wget https://github.com/ocaml/opam-rt/archive/$TRAVIS_PULL_REQUEST_BRANCH.tar.gz -O opam-rt.tar.gz || \
    wget https://github.com/ocaml/opam-rt/archive/master.tar.gz -O opam-rt.tar.gz
    tar -xzf opam-rt.tar.gz
    cd opam-rt-*
    opam install ./opam-rt.opam --deps-only -y
    make

    opam switch default
    opam switch remove $OPAMBSSWITCH --yes
  elif [ "$TRAVIS_BUILD_STAGE_NAME" != "Upgrade" ]; then
    # Note: these tests require a "system" compiler and will use the one in $OPAMBSROOT
    OPAMEXTERNALSOLVER="$EXTERNAL_SOLVER" make tests ||
      (tail -n 2000 _build/default/tests/fulltest-*.log; echo "-- TESTS FAILED --"; exit 1)
  fi
  echo -en "travis_fold:end:build\r"
)

if [ "$TRAVIS_BUILD_STAGE_NAME" = "Upgrade" ]; then
  OPAM12DIR=~/opam1.2
  CACHE=$OPAM12DIR/cache
  export OPAMROOT=$CACHE/root20
  echo -en "travis_fold:start:opam12\r"
  if [[ ! -f $CACHE/bin/opam ]]; then
    mkdir -p $CACHE/bin
    wget https://github.com/ocaml/opam/releases/download/1.2.2/opam-1.2.2-x86_64-Linux -O $CACHE/bin/opam
    chmod +x $CACHE/bin/opam
  fi
  export OPAMROOT=/tmp/opamroot
  rm -rf $OPAMROOT
  if [[ ! -d $CACHE/root ]]; then
    $CACHE/bin/opam init
    cp -r /tmp/opamroot/ $CACHE/root
  else
    cp -r $CACHE/root /tmp/opamroot
  fi
  echo -en "travis_fold:end:opam12\r"
  set +e
  opam update
  rcode=$?
  if [ $rcode -ne 10 ]; then
    echo "[31mBad return code $rcode, should be 10[0m";
    exit $rcode
  fi
  exit 0
fi

( # Finally run the tests, in a clean environment
  export OPAMKEEPLOGS=1

  if [[ $OPAM_TEST -eq 1 ]] ; then
    cd ~/build/opam-rt-*
    OPAMEXTERNALSOLVER="$EXTERNAL_SOLVER" make KINDS="local git" run
  else
    if [[ $COLD -eq 1 ]] ; then
      export PATH=$PWD/bootstrap/ocaml/bin:$PATH
    fi

    # Test basic actions
    opam init --bare default git+https://github.com/ocaml/opam-repository#8be4290a
    opam switch create default ocaml-system
    eval $(opam env)
    opam install lwt
    opam list
    opam config report
  fi
)

rm -f ~/local/bin/opam
