#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script bootstraps building a Bazel binary without Bazel.
# It should only be used to bootstrap Bazel itself.  The resulting
# binary can be found at output/bazel

set -o errexit

cd "$(dirname "$0")"

mkdir -p output/classes
mkdir -p output/test_classes
mkdir -p output/src
mkdir -p output/objs
mkdir -p output/native

# May be passed in from outside.
CXXFLAGS="$CXXFLAGS"
LDFLAGS="$LDFLAGS"
ZIPOPTS="$ZIPOPTS"

# TODO: CC target architecture needs to match JAVA_HOME.
CC=${CC:-gcc}
CXX=${CXX:-g++}
CXXSTD="c++0x"

unset JAVA_TOOL_OPTIONS
unset _JAVA_OPTIONS

JAVA_VERSION=${JAVA_VERSION:-"1.8"}
PLATFORM="$(uname -s | tr 'A-Z' 'a-z')"
ARCHIVE_CFLAGS=${ARCHIVE_CFLAGS:-""}
LDFLAGS=${LDFLAGS:-""}

# Extension for executables (.exe on Windows).
EXE_EXT=""

PROTO_FILES=$(ls src/main/protobuf/*.proto)
LIBRARY_JARS=$(find third_party -name *.jar | tr "\n" " ")
DIRS=$(echo src/{main/java,tools/xcode-common/java/com/google/devtools/build/xcode/{common,util}} output/src)

MSYS_DLLS=""
PATHSEP=":"

function fail() {
  echo "$1" >&2
  exit 1
}

function log() {
  if [[ -z "${QUIETMODE}" ]]; then
    echo -e "$1" >&2
  fi
}

# Create symlinks so we can use tools and examples from the base_workspace.
base_workspace=$(pwd)/base_workspace
mkdir -p "$base_workspace"
rm -f "${base_workspace}/tools" && ln -s "$(pwd)/tools" "${base_workspace}/tools"
rm -f "${base_workspace}/third_party" && ln -s "$(pwd)/third_party" "${base_workspace}/third_party"
rm -f "${base_workspace}/examples" && ln -s "$(pwd)/examples" "${base_workspace}/examples"

case "${PLATFORM}" in
linux)
  # Sorry, no static linking on linux for now.
  LDFLAGS="-lz -lrt $LDFLAGS"
  JNILIB="libunix.so"
  MD5SUM="md5sum"
  # JAVA_HOME must point to a Java 8 installation.
  JAVA_HOME="${JAVA_HOME:-$(readlink -f $(which javac) | sed 's_/bin/javac__')}"
  PROTOC=${PROTOC:-third_party/protobuf/protoc.linux-i686}
  ;;

darwin)
  JNILIB="libunix.dylib"
  MD5SUM="md5"
  LDFLAGS="-lz $LDFLAGS"
  if [[ -z "$JAVA_HOME" ]]; then
    JAVA_HOME="$(/usr/libexec/java_home -v 1.8+ 2> /dev/null)" \
      || fail "Could not find JAVA_HOME, please ensure a JDK (version 1.8+) is installed."
  fi
  PROTOC=${PROTOC:-third_party/protobuf/protoc.darwin}

  ;;

msys*|mingw*)
  # Use a simplified platform string.
  PLATFORM="mingw"
  # Workaround for msys issue which causes omission of std::to_string.
  CXXFLAGS="$CXXFLAGS -D_GLIBCXX_USE_C99 -D_GLIBCXX_USE_C99_DYNAMIC"
  LDFLAGS="-lz $LDFLAGS"
  MD5SUM="md5sum"
  EXE_EXT=".exe"
  PATHSEP=";"
  # Find the latest available version of the SDK.
  JAVA_HOME="${JAVA_HOME:-$(ls -d /c/Program\ Files/Java/jdk* | sort | tail -n 1)}"
  # We do not use the JNI library on Windows.
  JNILIB=""
  PROTOC=${PROTOC:-protoc}

  # The newer version of GCC on msys is stricter and removes some important function
  # declarations from the environment if using c++0x / c++11.
  CXXSTD="gnu++11"

  # Ensure that we are using the cygwin gcc, not the mingw64 gcc.
  ${CC} -v 2>&1 | grep "Target: .*mingw.*" > /dev/null &&
    fail "mingw gcc detected. Please set CC to point to the msys/Cygwin gcc."
  ${CXX} -v 2>&1 | grep "Target: .*mingw.*" > /dev/null &&
    fail "mingw g++ detected. Please set CXX to point to the msys/Cygwin g++."

  MSYS_DLLS="msys-2.0.dll msys-gcc_s-seh-1.dll msys-stdc++-6.dll"
  for dll in $MSYS_DLLS ; do
    cp "/usr/bin/$dll" "output/$dll"
  done
esac

[[ -x "${PROTOC-}" ]] \
    || fail "Protobuf compiler not found in ${PROTOC-}"

test -z "$JAVA_HOME" && fail "JDK not found, please set \$JAVA_HOME."
rm -f tools/jdk/jdk && ln -s "${JAVA_HOME}" tools/jdk/jdk

JAVAC="${JAVA_HOME}/bin/javac"

[[ -x "${JAVAC}" ]] \
    || fail "JAVA_HOME ($JAVA_HOME) is not a path to a working JDK."

JAVAC_VERSION=$("${JAVAC}" -version 2>&1)
[[ "$JAVAC_VERSION" =~ ^"javac 1"\.([89]|[1-9][0-9]).*$ ]] \
    || fail "JDK version is lower than 1.8, please set \$JAVA_HOME."

JAR="${JAVA_HOME}/bin/jar"

BLAZE_CC_FILES=(
src/main/cpp/blaze_startup_options.cc
src/main/cpp/blaze_startup_options_common.cc
src/main/cpp/blaze_util.cc
src/main/cpp/blaze_util_${PLATFORM}.cc
src/main/cpp/blaze.cc
src/main/cpp/option_processor.cc
src/main/cpp/util/errors.cc
src/main/cpp/util/file.cc
src/main/cpp/util/md5.cc
src/main/cpp/util/numbers.cc
src/main/cpp/util/port.cc
src/main/cpp/util/strings.cc
third_party/ijar/zip.cc
)

NATIVE_CC_FILES=(
src/main/cpp/util/md5.cc
src/main/native/localsocket.cc
src/main/native/process.cc
src/main/native/unix_jni.cc
src/main/native/unix_jni_${PLATFORM}.cc
)

IJAR_CC_FILES=(
third_party/ijar/ijar.cc
third_party/ijar/zip.cc
third_party/ijar/classfile.cc
)

# Compiles java classes.
function java_compilation() {
  name=$1
  directories=$2
  library_jars=$3
  output=$4

  classpath=${library_jars// /$PATHSEP}:$5
  sourcepath=${directories// /$PATHSEP}

  tmp="$(mktemp -d ${TMPDIR:-/tmp}/bazel.XXXXXXXX)"
  paramfile="${tmp}/param"
  errfile="${tmp}/err"

  mkdir -p "${output}/classes"

  trap "cat \"$errfile\"; rm -f \"$paramfile\" \"$errfile\"; rmdir \"$tmp\"" EXIT

  # Compile .java files (incl. generated ones) using javac
  log "Compiling $name code..."
  find ${directories} -name "*.java" > "$paramfile"

  if [ ! -z "$BAZEL_DEBUG_JAVA_COMPILATION" ]; then
    echo "directories=${directories}" >&2
    echo "classpath=${classpath}" >&2
    echo "sourcepath=${sourcepath}" >&2
    echo "libraries=${library_jars}" >&2
    echo "output=${output}/classes" >&2
    echo "List of compiled files:" >&2
    cat "$paramfile" >&2
  fi

  "${JAVAC}" -classpath "${classpath}" -sourcepath "${sourcepath}" \
      -d "${output}/classes" -source "$JAVA_VERSION" -target "$JAVA_VERSION" \
      "@${paramfile}" &> "$errfile" ||
      exit $?
  trap - EXIT
  rm "$paramfile" "$errfile"
  rmdir "$tmp"

  log "Extracting helper classes for $name..."
  for f in ${library_jars} ; do
    unzip -qn ${f} -d "${output}/classes"
  done
}

# Create the deploy JAR
function create_deploy_jar() {
  name=$1
  mainClass=$2
  output=$3
  shift 3
  packages=""
  for i in $output/classes/*; do
    package=$(basename $i)
    if [[ "$package" != "META-INF" ]]; then
      packages="$packages -C $output/classes $package"
    fi
  done

  log "Creating $name.jar..."
  echo "Main-Class: $mainClass" > $output/MANIFEST.MF
  "$JAR" cmf $output/MANIFEST.MF $output/$name.jar $packages "$@"
}

function cc_compile() {
  local OBJDIR=$1
  shift
  mkdir -p "output/${OBJDIR}"
  for FILE in "$@"; do
    if [[ ! "${FILE}" =~ ^-.*$ ]]; then
      local OBJ=$(basename "${FILE}").o
      "${CXX}" \
          -I. \
          ${ARCHIVE_CFLAGS} \
          ${CFLAGS} \
          -std=$CXXSTD \
          -c \
          -DBLAZE_JAVA_CPU=\"k8\" \
          -DBLAZE_OPENSOURCE=1 \
          -o "output/${OBJDIR}/${OBJ}" \
          "${FILE}"
    fi
  done
}

function cc_link() {
  local OBJDIR=$1
  local OUTPUT=$2
  shift 2
  local FILES=()
  for FILE in "$@"; do
    local OBJ=$(basename "${FILE}").o
    FILES+=("output/${OBJDIR}/${OBJ}")
  done
  "${CXX}" -o ${OUTPUT} "${FILES[@]}" -lstdc++ ${LDFLAGS}
}

function cc_build() {
  local NAME=$1
  local OBJDIR=$2
  local OUTPUT=$3
  shift 3
  log "Compiling ${NAME} .cc files..."
  cc_compile "${OBJDIR}" "$@"
  log "Linking ${NAME}..."
  cc_link "${OBJDIR}" "${OUTPUT}" "$@"
}

if [ -z "${BAZEL_SKIP_JAVA_COMPILATION}" ]; then
  log "Compiling Java stubs for protocol buffers..."
  for f in $PROTO_FILES ; do
    "${PROTOC}" -Isrc/main/protobuf/ --java_out=output/src "$f"
  done

  java_compilation "Bazel Java" "$DIRS" "$LIBRARY_JARS" "output"

  # help files: all non java and BUILD files in src/main/java.
  for i in $(find src/main/java -type f -a \! -name '*.java' -a \! -name 'BUILD' | sed 's|src/main/java/||'); do
    mkdir -p $(dirname output/classes/$i)
    cp src/main/java/$i output/classes/$i
  done

  # build-data.properties
  git_version="non-git"
  if [ -x "$(which git || true)" ] && [ -d .git ]; then
    git_version=$(git log -1 --oneline | cut -d " " -f 1 2>/dev/null || \
      echo "non-git")
  fi
  cat >output/classes/build-data.properties <<EOF
build.time=$(date)
build.label=bazel-compile.sh-${git_version}
EOF
  create_deploy_jar "libblaze" "com.google.devtools.build.lib.bazel.BazelMain" \
      output third_party/javascript
fi

cc_build "client" "objs" "output/client" ${BLAZE_CC_FILES[@]}

if [ ! -z "$JNILIB" ] ; then
  log "Compiling JNI libraries..."
  for FILE in "${NATIVE_CC_FILES[@]}"; do
    OUT=$(basename "${FILE}").o
    "${CXX}" \
      -I . \
      -I "${JAVA_HOME}/include/" \
      -I "${JAVA_HOME}/include/${PLATFORM}" \
      -std=$CXXSTD \
      -fPIC \
      -c \
      -D_JNI_IMPLEMENTATION_ \
      -DBLAZE_JAVA_CPU=\"k8\" \
      -DBLAZE_OPENSOURCE=1 \
      -o "output/native/${OUT}" \
      "${FILE}"
  done

  log "Linking ${JNILIB}..."
  "${CXX}" -o output/${JNILIB} $JNI_LD_ARGS -shared output/native/*.o -l stdc++
fi

log "Compiling build-runfiles..."
# Clang on Linux requires libstdc++
"${CXX}" -o output/build-runfiles -std=c++0x -l stdc++ src/main/tools/build-runfiles.cc

log "Compiling process-wrapper..."
"${CC}" -o output/process-wrapper -std=c99 src/main/tools/process-wrapper.c
if [[ $PLATFORM == "linux" ]]; then
  log "Compiling sandbox..."
  "${CC}" -o output/namespace-sandbox -std=c99 src/main/tools/namespace-sandbox.c
fi

cp src/main/tools/build_interface_so output/build_interface_so
cp src/main/tools/jdk.* output

touch output/client_info
chmod 755 output/client_info

log "Creating Bazel self-extracting archive..."
TO_ZIP="libblaze.jar ${JNILIB} build-runfiles${EXE_EXT} process-wrapper${EXE_EXT} client_info build_interface_so ${MSYS_DLLS} jdk.WORKSPACE jdk.BUILD"
if [[ $PLATFORM == "linux" ]]; then
    TO_ZIP="$TO_ZIP namespace-sandbox${EXE_EXT}"
fi

(cd output/ ; cat client ${TO_ZIP} | ${MD5SUM} | awk '{ print $1; }' > install_base_key)
(cd output/ ; echo "${JAVA_VERSION}" > java.version)
(cd output/ ; find . -type f | xargs -P 10 touch -t 198001010000)
(cd output/ ; zip $ZIPOPTS -q package.zip ${TO_ZIP} install_base_key java.version)
cat output/client output/package.zip > output/bazel
zip -qA output/bazel \
  || echo "(Non-critical error, ignore.)"

chmod 755 output/bazel

function bootstrap_tool() {
  output/bazel --blazerc=/dev/null build \
      --singlejar_top=//src/java_tools/singlejar:bootstrap_deploy.jar \
      --javabuilder_top=//src/java_tools/buildjar:bootstrap_deploy.jar \
      --javacopt="-source ${JAVA_VERSION} -target ${JAVA_VERSION}" \
      "${@}"
}

# Compile ijar
bootstrap_tool //third_party/ijar
mkdir -p tools/jdk
cp -f bazel-bin/third_party/ijar/ijar tools/jdk
chmod 755 tools/jdk/ijar

if [ -z "${BAZEL_SKIP_SINGLEJAR_COMPILATION}" ]; then
  # Compile singlejar, a jar suitable for deployment.
  bootstrap_tool //src/java_tools/singlejar:SingleJar_deploy.jar
  mkdir -p tools/jdk
  cp -f bazel-bin/src/java_tools/singlejar/SingleJar_deploy.jar tools/jdk
  chmod 644 tools/jdk/SingleJar_deploy.jar
fi

if [ -z "${BAZEL_SKIP_BUILDJAR_COMPILATION}" ]; then
  bootstrap_tool //src/java_tools/buildjar:JavaBuilder_deploy.jar
  mkdir -p tools/jdk
  cp -f bazel-bin/src/java_tools/buildjar/JavaBuilder_deploy.jar tools/jdk
  chmod 644 tools/jdk/JavaBuilder_deploy.jar
fi

if [[ $PLATFORM == "darwin" ]] && [ -z "${BAZEL_SKIP_OBJCTOOLS_COMPILATION}" ]; then
  log "Creating objc helper tools..."

  OBJC_TOOLS="src/tools/xcode-common/java/com/google/devtools/build/xcode/actoolzip:actoolzip_deploy.jar \
      src/tools/xcode-common/java/com/google/devtools/build/xcode/ibtoolzip:ibtoolzip_deploy.jar \
      src/objc_tools/momczip:momczip_deploy.jar \
      src/objc_tools/bundlemerge:bundlemerge_deploy.jar \
      src/objc_tools/plmerge:plmerge_deploy.jar \
      src/objc_tools/xcodegen:xcodegen_deploy.jar"
  bootstrap_tool ${OBJC_TOOLS}

  for i in ${OBJC_TOOLS}; do
      p=bazel-bin/$(echo $i | sed "s|:|/|")
      cp $p tools/objc/precomp_$(basename $p)
      chmod 0644 tools/objc/precomp_$(basename $p)
  done
fi

# Create a bazelrc file with the base_workspace directory in the package path.
bazelrc='build --package_path %workspace%:'${base_workspace}
bazelrc="${bazelrc}"$'\nfetch --package_path %workspace%:'${base_workspace}
bazelrc="${bazelrc}"$'\nquery --package_path %workspace%:'${base_workspace}
if [ -z "${HOME-}" ]; then
  warning="No \$HOME variable set, cannot write .bazelrc file."
  warning="$warning Consider adding $base_workspace to your package path"
  log $warning
elif [ ! -f $HOME/.bazelrc ]; then
  log "Creating a .bazelrc pointing to $base_workspace"
  echo "$bazelrc" > $HOME/.bazelrc
else
  while read rcline; do
    if ! grep -q "$rcline" $HOME/.bazelrc; then
      warning="You already have a .bazelrc. Make sure it contains the "
      warning="$warning following package paths:\n$bazelrc"
      log "$warning"
      break
    fi
  done <<< "$bazelrc"
fi

log "Build successful! Binary is here: ${PWD}/output/bazel"
