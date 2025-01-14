#!/usr/bin/env bash

DOCKER="${DOCKER:-"docker"}"

script_name=$(basename "${0}")
script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
work_dir="$( cd "${script_dir}/../.." && pwd )"

usage() {
	cat <<EOF
Usage: ${script_name} [OPTIONS]
    -d Device type name
    -s Shared build directory
    -i Bitbake targets (defaults to the device type default, balena-image or balena-image-flasher)
    -b Bitbake arguments (optional, for example '-b "-c cleanall"')
    -g Barys extra arguments (optional, for example '-g "-a VARIABLE=value"')
    -k Keep local containers (optional - by default container iamges are removed)
    -h Display usage
EOF
	exit 0
}

source "${script_dir}/../automation/include/balena-lib.inc"

__check_docker() {
	if ! "${DOCKER}" info > /dev/null 2>&1; then
		return 1
	fi
	return 0
}

BUILD_CONTAINER_NAME=yocto-build-$$

docker_build_cleanup() {
	echo "[INFO] $0: Cleanup."

	# Stop docker container
	echo "[INFO] $0: Cleaning up yocto-build container."
	"${DOCKER}" stop $BUILD_CONTAINER_NAME 2> /dev/null || true
	"${DOCKER}" rm --volumes $BUILD_CONTAINER_NAME 2> /dev/null || true

	if [ "$1" = "fail" ]; then
		exit 1
	fi
}
trap 'docker_build_cleanup fail' SIGINT SIGTERM

balena_build_run_barys() {
	local _device_type="${1}"
	local _shared_dir="${2}"
	local _token="${4}"
	local _keep_helpers="${5}"
	local _bitbake_args="${6}"
	local _bitbake_targets="${7}"
	local _barys_args="${8}"
	local _docker_run_args="${9:-"--rm"}"
	local _dl_dir
	local _sstate_dir
	local _image_repo="${HELPER_IMAGE_REPO:-"ghcr.io/balena-os/balena-yocto-scripts"}"

	[ -z "${_device_type}" ] && echo "Device type is required"  && exit 1
	[ -z "${_shared_dir}" ] && echo "Shared directory path is required"  && exit 1
	[ -z "${_bitbake_args}" ] && _bitbake_args=""
	[ -z "${_bitbake_targets}" ] && _bitbake_targets=""
	_dl_dir="${_shared_dir}/shared-downloads"
	_sstate_dir="${_shared_dir}/${_device_type}/sstate"
	mkdir -p "${_dl_dir}"
	mkdir -p "${_sstate_dir}"
	[ -n "${_bitbake_args}" ] && _bitbake_args="--bitbake-args ${_bitbake_args}"
	[ -n "${_bitbake_targets}" ] && _bitbake_targets="--bitbake-target ${_bitbake_targets}"

	if ! __check_docker; then
		echo "Docker needs to be installed"
		exit 1
	fi

	pushd "${work_dir}"
	printf "Submodule details:\n\n"
	git submodule status
	popd

	"${DOCKER}" stop $BUILD_CONTAINER_NAME 2> /dev/null || true
	"${DOCKER}" rm --volumes $BUILD_CONTAINER_NAME 2> /dev/null || true
	if ! balena_lib_docker_pull_helper_image "${HELPER_IMAGE_REPO}" "" "yocto-build-env" helper_image_id; then
		exit 1
	fi
	${DOCKER} run --rm ${_docker_run_args} \
		-v "${work_dir}":/work \
		-v "${_dl_dir}":/yocto/shared-downloads \
		-v "${_sstate_dir}":/yocto/shared-sstate \
		-e BUILDER_UID="$(id -u)" \
		-e VERBOSE="${VERBOSE}" \
		-e BUILDER_GID="$(id -g)" \
		--name $BUILD_CONTAINER_NAME \
		--privileged \
		"${helper_image_id}" \
		/prepare-and-start.sh \
		--log \
		--machine "${_device_type}" \
		${_bitbake_args} \
		${_bitbake_targets} \
		${_barys_args} \
		--shared-downloads /yocto/shared-downloads \
		--shared-sstate /yocto/shared-sstate \
		--rm-work

	if [ "${_keep_helpers}" = "0" ]; then
		balena_lib_docker_remove_helper_images "${HELPER_IMAGE_REPO}"
	fi
}

main() {
	local _device_type
	local _token
	local _shared_dir
	local _bitbake_args
	local _bitbake_targets
	local _barys_args
	local _keep_helpers=0
	## Sanity checks
	if [ ${#} -lt 1 ] ; then
		usage
		exit 1
	else
		while getopts "hd:s:b:i:g:k" c; do
			case "${c}" in
				d) _device_type="${OPTARG}";;
				s) _shared_dir="${OPTARG}" ;;
				b) _bitbake_args="${OPTARG}" ;;
				i) _bitbake_targets="${OPTARG}" ;;
				g) _barys_args="${OPTARG}" ;;
				k) _keep_helpers=1 ;;
				h) usage;;
				*) usage;exit 1;;
			esac
		done

		_device_type="${_device_type:-"${MACHINE}"}"
		[ -z "${_device_type}" ] && echo "Device type is required" && exit 1

		_shared_dir="${_shared_dir:-"${YOCTO_DIR}"}"
		[ -z "${_shared_dir}" ] && echo "Shared directory is required" && exit 1

		balena_build_run_barys "${_device_type}" "${_shared_dir}" "${_keep_helpers}" "${_bitbake_args}" "${_bitbake_targets}" "${_barys_args}"
	fi
}

main "${@}"
